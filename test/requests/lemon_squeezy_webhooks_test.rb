require "test_helper"
require "openssl"
require "stringio"

class LemonSqueezyWebhooksTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = "synthetic-webhook-secret"
  CUSTOMER_SENTINEL = "private-customer@example.test"

  setup do
    @original_secret = Rails.configuration.x.billing.lemon_squeezy.webhook_secret
    @original_environment = Rails.configuration.x.billing.lemon_squeezy.environment
    @original_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = SECRET
    Rails.configuration.x.billing.lemon_squeezy.environment = "test"
    Rails.configuration.x.billing.lemon_squeezy.store_id = "61001"
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = @original_secret
    Rails.configuration.x.billing.lemon_squeezy.environment = @original_environment
    Rails.configuration.x.billing.lemon_squeezy.store_id = @original_store_id
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "valid signed event is durably stored and enqueued without changing subscriptions" do
    body = valid_body

    assert_no_difference -> { Billing::Subscription.count } do
      assert_difference -> { Billing::WebhookEvent.count }, 1 do
        assert_enqueued_jobs 1 do
          post_signed(body)
        end
      end
    end

    assert_response :ok
    event = Billing::WebhookEvent.order(:id).last
    assert_equal "lemon_squeezy", event.provider
    assert_equal "subscription_updated", event.event_name
    assert_equal "subscriptions", event.external_resource_type
    assert_equal "sub_123", event.external_resource_id
    assert_equal Digest::SHA256.hexdigest(body), event.body_sha256
    assert_equal event.provider_resource_id, event.external_resource_id
    assert_equal event.snapshot, event.payload
    assert_equal event.attempt_count, event.attempts_count
    assert_equal "active", event.payload.fetch("status")
    assert_not_includes event.payload.to_json, CUSTOMER_SENTINEL
    assert_predicate event, :status_received?
    assert_nil event.processing_started_at
    assert_nil event.processed_at
    assert_nil event.failed_at
    assert event.enqueued_at
    assert_enqueued_with(job: Billing::ProcessWebhookJob, args: [ event.id ], queue: "billing")
  end

  test "endpoint is isolated from parameter parsing session authentication and tenant controllers" do
    assert_equal ActionController::Metal, Webhooks::LemonSqueezyController.superclass
    assert_not_operator Webhooks::LemonSqueezyController, :<, ApplicationController

    route = Rails.application.routes.recognize_path(
      "/webhooks/lemon_squeezy",
      method: :post
    )
    assert_equal "webhooks/lemon_squeezy", route.fetch(:controller)
    assert_equal "create", route.fetch(:action)
  end

  test "invalid signature is rejected before malformed JSON is parsed" do
    malformed_body = %({"customer_email":"#{CUSTOMER_SENTINEL}")

    assert_no_difference -> { Billing::WebhookEvent.count } do
      assert_no_enqueued_jobs do
        post_raw(malformed_body, signature: "0" * 64)
      end
    end

    assert_response :unauthorized
  end

  test "missing signature is rejected" do
    assert_no_difference -> { Billing::WebhookEvent.count } do
      assert_no_enqueued_jobs do
        post_raw(valid_body, signature: nil)
      end
    end

    assert_response :unauthorized
  end

  test "validly signed malformed JSON is rejected without a receipt" do
    malformed_body = %({"customer_email":"#{CUSTOMER_SENTINEL}")

    assert_no_difference -> { Billing::WebhookEvent.count } do
      assert_no_enqueued_jobs do
        post_signed(malformed_body)
      end
    end

    assert_response :bad_request
  end

  test "duplicate delivery returns success and is not enqueued twice" do
    body = valid_body

    assert_difference -> { Billing::WebhookEvent.count }, 1 do
      assert_enqueued_jobs 1 do
        2.times do
          post_signed(body)
          assert_response :ok
        end
      end
    end

    assert_equal 1, Billing::WebhookEvent.where(body_sha256: Digest::SHA256.hexdigest(body)).count
  end

  test "enqueue failure keeps a durable recoverable receipt and still acknowledges delivery" do
    body = valid_body

    original_perform_later = Billing::ProcessWebhookJob.method(:perform_later)
    Billing::ProcessWebhookJob.define_singleton_method(:perform_later) { |*| false }

    begin
      assert_difference -> { Billing::WebhookEvent.count }, 1 do
        assert_no_enqueued_jobs do
          post_signed(body)
        end
      end
    ensure
      Billing::ProcessWebhookJob.define_singleton_method(:perform_later, original_perform_later)
    end

    assert_response :ok
    event = Billing::WebhookEvent.order(:id).last
    assert_predicate event, :status_received?
    assert_nil event.enqueued_at
    assert_nil event.processing_started_at
    assert_nil event.failed_at
  end

  test "unsupported signed event is recorded as ignored without enqueueing" do
    payload = JSON.parse(valid_body)
    payload["meta"]["event_name"] = "order_created"
    payload["data"]["type"] = "orders"
    body = JSON.generate(payload)

    assert_difference -> { Billing::WebhookEvent.count }, 1 do
      assert_no_enqueued_jobs do
        post_signed(body)
      end
    end

    assert_response :ok
    event = Billing::WebhookEvent.order(:id).last
    assert_predicate event, :status_ignored?
    assert_equal "unsupported_event", event.payload.fetch("reason_code")
    assert event.processed_at
    assert_nil event.enqueued_at
  end

  test "signed invalid envelope is quarantined without processing" do
    body = JSON.generate("meta" => [], "data" => [])

    assert_difference -> { Billing::WebhookEvent.count }, 1 do
      assert_no_enqueued_jobs do
        post_signed(body)
      end
    end

    assert_response :ok
    event = Billing::WebhookEvent.order(:id).last
    assert_predicate event, :status_quarantined?
    assert_equal "invalid_event_envelope", event.error_code
    assert_equal "invalid_event_envelope", event.payload.fetch("reason_code")
    assert event.processed_at
    assert_nil event.enqueued_at
  end

  test "signed oversized and non-JSON requests are rejected before parsing" do
    oversized_body = "x" * (Billing::Webhooks::Receive::MAX_BODY_BYTES + 1)
    post_signed(oversized_body)
    assert_response 413

    body = valid_body
    post_raw(body, signature: signature_for(body), content_type: "text/plain")
    assert_response :unsupported_media_type

    assert_equal 0, Billing::WebhookEvent.count
    assert_no_enqueued_jobs
  end

  test "missing server signing secret fails closed without parsing or persistence" do
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = nil

    assert_no_difference -> { Billing::WebhookEvent.count } do
      assert_no_enqueued_jobs do
        post_raw(%({"customer_email":"#{CUSTOMER_SENTINEL}"}), signature: "0" * 64)
      end
    end

    assert_response :service_unavailable
  end

  test "missing store configuration cannot bypass signature-first rejection" do
    Rails.configuration.x.billing.lemon_squeezy.store_id = nil
    malformed_body = %({"customer_email":"#{CUSTOMER_SENTINEL}")

    post_raw(malformed_body, signature: nil)
    assert_response :unauthorized

    post_signed(malformed_body)
    assert_response :bad_request

    body = valid_body
    post_signed(body)
    assert_response :service_unavailable
    assert_equal 0, Billing::WebhookEvent.count
    assert_no_enqueued_jobs
  end

  test "missing or mismatched test mode is quarantined fail closed" do
    missing_payload = JSON.parse(valid_body)
    missing_payload.fetch("data").fetch("attributes").delete("test_mode")
    mismatched_payload = JSON.parse(valid_body)
    mismatched_payload.fetch("data").fetch("attributes")["test_mode"] = false

    assert_difference -> { Billing::WebhookEvent.count }, 2 do
      assert_no_enqueued_jobs do
        post_signed(JSON.generate(missing_payload))
        assert_response :ok
        post_signed(JSON.generate(mismatched_payload))
        assert_response :ok
      end
    end

    events = Billing::WebhookEvent.order(id: :desc).limit(2)
    assert events.all?(&:status_quarantined?)
    assert events.all? { |event| event.error_code == "environment_mismatch" }
    assert events.all? { |event| event.payload.fetch("reason_code") == "environment_mismatch" }
  end

  test "request body signature secret and customer payload are not logged" do
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    original_loggers = capture_loggers
    assign_loggers(logger)
    body = valid_body
    signature = signature_for(body)

    post_raw(body, signature: signature)
    assert_response :ok

    malformed_body = %({"customer_email":"#{CUSTOMER_SENTINEL}")
    post_raw(malformed_body, signature: signature_for(malformed_body))
    assert_response :bad_request

    quarantined_payload = JSON.parse(valid_body)
    quarantined_payload.fetch("data").fetch("attributes")["test_mode"] = false
    quarantined_body = JSON.generate(quarantined_payload)
    post_raw(quarantined_body, signature: signature_for(quarantined_body))
    assert_response :ok

    logs = output.string
    assert_not_includes logs, body
    assert_not_includes logs, malformed_body
    assert_not_includes logs, quarantined_body
    assert_not_includes logs, CUSTOMER_SENTINEL
    assert_not_includes logs, SECRET
    assert_not_includes logs, signature
  ensure
    restore_loggers(original_loggers) if original_loggers
  end

  private
    def valid_body
      JSON.generate(
        "meta" => { "event_name" => "subscription_updated" },
        "data" => {
          "type" => "subscriptions",
          "id" => "sub_123",
          "attributes" => {
            "store_id" => 61_001,
            "customer_id" => 62_002,
            "product_id" => 63_003,
            "variant_id" => 64_004,
            "status" => "active",
            "test_mode" => true,
            "renews_at" => "2026-08-16T00:00:00Z",
            "updated_at" => "2026-07-16T00:00:00Z",
            "user_email" => CUSTOMER_SENTINEL,
            "urls" => { "customer_portal" => "https://provider.example/signed" }
          }
        }
      )
    end

    def post_signed(body)
      post_raw(body, signature: signature_for(body))
    end

    def post_raw(body, signature:, content_type: "application/json")
      headers = { "CONTENT_TYPE" => content_type }
      headers["HTTP_X_SIGNATURE"] = signature if signature
      post lemon_squeezy_webhook_path, params: body, headers: headers
    end

    def signature_for(body)
      OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)
    end

    def capture_loggers
      {
        rails: Rails.logger,
        action_controller: ActionController::Base.logger,
        active_record: ActiveRecord::Base.logger,
        active_job: ActiveJob::Base.logger
      }
    end

    def assign_loggers(logger)
      Rails.logger = logger
      ActionController::Base.logger = logger
      ActiveRecord::Base.logger = logger
      ActiveJob::Base.logger = logger
    end

    def restore_loggers(loggers)
      Rails.logger = loggers.fetch(:rails)
      ActionController::Base.logger = loggers.fetch(:action_controller)
      ActiveRecord::Base.logger = loggers.fetch(:active_record)
      ActiveJob::Base.logger = loggers.fetch(:active_job)
    end
end
