require "test_helper"
require "openssl"
require "stringio"
require_relative "../support/billing_test_helper"

class LemonSqueezyWebhooksTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include BillingTestHelper

  SECRET = "synthetic-webhook-secret"
  PREVIOUS_SECRET = "synthetic-previous-webhook-secret"
  CUSTOMER_SENTINEL = "private-customer@example.test"

  setup do
    @original_secret = Rails.configuration.x.billing.lemon_squeezy.webhook_secret
    @original_previous_secret = Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret
    @original_previous_secret_expires_at =
      Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at
    @original_environment = Rails.configuration.x.billing.lemon_squeezy.environment
    @original_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = SECRET
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret = nil
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at = nil
    Rails.configuration.x.billing.lemon_squeezy.environment = "test"
    Rails.configuration.x.billing.lemon_squeezy.store_id = "61001"
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = @original_secret
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret = @original_previous_secret
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at =
      @original_previous_secret_expires_at
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
    assert_equal Billing::WebhookEvent::CURRENT_INGRESS_VERSION, event.ingress_version
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

  test "ingress rate limit returns a bounded retry delay before webhook processing" do
    cache_key = [
      "rate-limit",
      "webhooks/lemon_squeezy",
      Webhooks::LemonSqueezyController::RATE_LIMIT_NAME,
      "127.0.0.1"
    ].join(":")
    Rails.cache.write(
      cache_key,
      Webhooks::LemonSqueezyController::RATE_LIMIT,
      expires_in: Webhooks::LemonSqueezyController::RATE_LIMIT_WINDOW
    )

    original_call = Billing::Webhooks::Receive.method(:call)
    Billing::Webhooks::Receive.define_singleton_method(:call) do |**|
      raise "webhook processing must not run after the ingress limit"
    end

    begin
      post_raw("not-read", signature: nil)
    ensure
      Billing::Webhooks::Receive.define_singleton_method(:call, original_call)
    end

    assert_response :too_many_requests
    assert_equal Webhooks::LemonSqueezyController::RATE_LIMIT_WINDOW.to_i.to_s,
      response.headers.fetch("Retry-After")
    assert_empty response.body
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

  test "an unexpired previous signing secret is accepted but stops working at expiry" do
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret = PREVIOUS_SECRET
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at = 1.hour.from_now
    accepted_body = valid_body

    assert_difference -> { Billing::WebhookEvent.count }, 1 do
      assert_enqueued_jobs 1 do
        post_signed(accepted_body, secret: PREVIOUS_SECRET)
      end
    end
    assert_response :ok

    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at = Time.current
    expired_body = subscription_body("subscription_created", status: "active")

    assert_no_difference -> { Billing::WebhookEvent.count } do
      assert_no_enqueued_jobs do
        post_signed(expired_body, secret: PREVIOUS_SECRET)
      end
    end
    assert_response :unauthorized
  end

  test "the same body signed with previous and current secrets creates one receipt" do
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret = PREVIOUS_SECRET
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at = 1.hour.from_now
    body = valid_body

    assert_difference -> { Billing::WebhookEvent.count }, 1 do
      assert_enqueued_jobs 1 do
        post_signed(body, secret: PREVIOUS_SECRET)
        assert_response :ok
        post_signed(body, secret: SECRET)
        assert_response :ok
      end
    end

    assert_equal 1, Billing::WebhookEvent.where(body_sha256: Digest::SHA256.hexdigest(body)).count
  end

  test "previous-secret acceptance emits only a bounded rotation marker" do
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret = PREVIOUS_SECRET
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at = 1.hour.from_now
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    original_loggers = capture_loggers
    assign_loggers(logger)

    current_body = subscription_body("subscription_created", status: "active")
    post_signed(current_body)
    assert_response :ok
    assert_not_includes output.string, "billing_webhook_previous_secret_accepted"

    output.truncate(0)
    output.rewind
    previous_body = valid_body
    previous_signature = signature_for(previous_body, secret: PREVIOUS_SECRET)
    post_raw(previous_body, signature: previous_signature)
    assert_response :ok

    logs = output.string
    assert_includes logs, "billing_webhook_previous_secret_accepted request_id="
    assert_not_includes logs, previous_body
    assert_not_includes logs, CUSTOMER_SENTINEL
    assert_not_includes logs, SECRET
    assert_not_includes logs, PREVIOUS_SECRET
    assert_not_includes logs, previous_signature
  ensure
    restore_loggers(original_loggers) if original_loggers
  end

  test "a valid signed resend re-screens and grants provenance to an exact legacy receipt" do
    user = create_test_user(email_address: "legacy-resend-#{SecureRandom.hex(4)}@example.test")
    organization, = create_test_organization_with_owner(
      owner: user,
      name: "Legacy Webhook Organization",
      slug: "legacy-webhook-#{SecureRandom.hex(4)}"
    )
    plan_price = create_test_plan_price(plan: create_test_plan)
    now = Time.current.change(usec: 0)
    nonce = Billing::Checkouts::Token.generate_nonce
    expires_at = now + 15.minutes
    token = Billing::Checkouts::Token.issue(
      organization: organization,
      plan_price: plan_price,
      user: user,
      nonce: nonce,
      expires_at: expires_at
    )
    payload = JSON.parse(subscription_body("subscription_created", status: "active"))
    payload.fetch("meta")["custom_data"] = { "checkout_attempt_token" => token }
    body = JSON.generate(payload)
    post_signed(body)
    assert_response :ok

    event = Billing::WebhookEvent.order(:id).last
    legacy_payload = event.payload.slice(
      "event_name",
      "resource_type",
      "provider_resource_id",
      "provider_subscription_id",
      "provider_store_id",
      "test_mode",
      "checkout_token_digest"
    )
    Billing::WebhookEvent.where(id: event.id).update_all(
      ingress_version: nil,
      payload: legacy_payload,
      snapshot: legacy_payload,
      enqueued_at: event.enqueued_at
    )
    clear_enqueued_jobs

    assert_no_difference -> { Billing::WebhookEvent.count } do
      assert_enqueued_with(job: Billing::ProcessWebhookJob, args: [ event.id ], queue: "billing") do
        post_signed(body)
      end
    end

    assert_response :ok
    event.reload
    assert_equal Billing::WebhookEvent::CURRENT_INGRESS_VERSION, event.ingress_version
    assert_equal organization.public_id, event.payload.fetch("checkout_organization_public_id")
    assert_equal plan_price.id, event.payload.fetch("checkout_plan_price_id")
    assert_equal user.id, event.payload.fetch("checkout_user_id")
    assert_equal expires_at.utc.iso8601(6), event.payload.fetch("checkout_expires_at")
    assert_equal Billing::Checkouts::Token.digest_nonce(nonce),
      event.payload.fetch("checkout_token_digest")
    assert_not_includes event.payload.to_json, token
    assert_not_includes event.payload.to_json, nonce
    assert event.enqueued_at
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

  test "supported lifecycle and payment events are handed off with the correct subscription identity" do
    bodies = [
      subscription_body("subscription_created", status: "active"),
      subscription_body("subscription_expired", status: "expired"),
      payment_body("subscription_payment_success", invoice_id: "invoice_success", status: "paid"),
      payment_body("subscription_payment_failed", invoice_id: "invoice_failed", status: "pending"),
      payment_body("subscription_payment_recovered", invoice_id: "invoice_recovered", status: "paid")
    ]

    assert_difference -> { Billing::WebhookEvent.count }, bodies.length do
      assert_enqueued_jobs bodies.length do
        bodies.each do |body|
          post_signed(body)
          assert_response :ok
        end
      end
    end

    expired_event = Billing::WebhookEvent.find_by!(event_name: "subscription_expired")
    assert_equal "subscriptions", expired_event.external_resource_type
    assert_equal "sub_123", expired_event.payload.fetch("provider_subscription_id")
    assert_equal "expired", expired_event.payload.fetch("status")

    payment_events = Billing::WebhookEvent.where(event_name: Billing::Webhooks::Receive::PAYMENT_EVENTS)
    assert_equal 3, payment_events.count
    payment_events.each do |event|
      assert_equal "subscription-invoices", event.external_resource_type
      assert_equal "sub_123", event.payload.fetch("provider_subscription_id")
      assert event.payload.key?("payment_status")
      assert_not event.payload.key?("status")
      assert_predicate event, :status_received?
    end
  end

  test "payment events with the wrong resource shape are quarantined without handoff" do
    wrong_type = JSON.parse(subscription_body("subscription_payment_success", status: "active"))
    missing_subscription = JSON.parse(
      payment_body("subscription_payment_failed", invoice_id: "invoice_missing_subscription", status: "pending")
    )
    missing_subscription.fetch("data").fetch("attributes").delete("subscription_id")

    assert_difference -> { Billing::WebhookEvent.count }, 2 do
      assert_no_enqueued_jobs do
        [ wrong_type, missing_subscription ].each do |payload|
          post_signed(JSON.generate(payload))
          assert_response :ok
        end
      end
    end

    events = Billing::WebhookEvent.order(id: :desc).limit(2)
    assert events.all?(&:status_quarantined?)
    assert events.all? { |event| event.error_code == "invalid_subscription_resource" }
  end

  test "verified checkout token claims are retained without persisting the token or nonce" do
    user = create_test_user(email_address: "webhook-context-#{SecureRandom.hex(4)}@example.test")
    organization, = create_test_organization_with_owner(
      owner: user,
      name: "Webhook Context Organization",
      slug: "webhook-context-#{SecureRandom.hex(4)}"
    )
    plan_price = create_test_plan_price(plan: create_test_plan)
    now = Time.current.change(usec: 0)
    nonce = Billing::Checkouts::Token.generate_nonce
    expires_at = now + 15.minutes
    token = Billing::Checkouts::Token.issue(
      organization: organization,
      plan_price: plan_price,
      user: user,
      nonce: nonce,
      expires_at: expires_at
    )

    %w[checkout_attempt_token checkout_context].each do |custom_key|
      payload = JSON.parse(subscription_body("subscription_created", status: "active"))
      payload.fetch("meta")["custom_data"] = { custom_key => token }

      post_signed(JSON.generate(payload))
      assert_response :ok
    end

    events = Billing::WebhookEvent.where(event_name: "subscription_created").order(:id).last(2)
    assert_equal 2, events.size
    events.each do |event|
      snapshot = event.payload
      assert_equal Billing::Checkouts::Token.digest_nonce(nonce), snapshot.fetch("checkout_token_digest")
      assert_equal organization.public_id, snapshot.fetch("checkout_organization_public_id")
      assert_equal plan_price.id, snapshot.fetch("checkout_plan_price_id")
      assert_equal user.id, snapshot.fetch("checkout_user_id")
      assert_equal expires_at.utc.iso8601(6), snapshot.fetch("checkout_expires_at")
      assert_not_includes snapshot.to_json, token
      assert_not_includes snapshot.to_json, nonce
    end
  end

  test "invalid or ambiguous checkout context is not retained as provider authority" do
    payload = JSON.parse(subscription_body("subscription_created", status: "active"))
    payload.fetch("meta")["custom_data"] = {
      "checkout_attempt_token" => "invalid-signed-context",
      "checkout_context" => "conflicting-signed-context"
    }

    assert_difference -> { Billing::WebhookEvent.count }, 1 do
      assert_enqueued_jobs 1 do
        post_signed(JSON.generate(payload))
      end
    end

    assert_response :ok
    snapshot = Billing::WebhookEvent.order(:id).last.payload
    assert_not snapshot.keys.any? { |key| key.start_with?("checkout_") }
    assert_not_includes snapshot.to_json, "invalid-signed-context"
    assert_not_includes snapshot.to_json, "conflicting-signed-context"
  end

  test "expired signed checkout context is not retained as provider authority" do
    user = create_test_user(email_address: "expired-context-#{SecureRandom.hex(4)}@example.test")
    organization, = create_test_organization_with_owner(
      owner: user,
      name: "Expired Context Organization",
      slug: "expired-context-#{SecureRandom.hex(4)}"
    )
    plan_price = create_test_plan_price(plan: create_test_plan)
    issued_at = Time.current.change(usec: 0)
    token = Billing::Checkouts::Token.issue(
      organization: organization,
      plan_price: plan_price,
      user: user,
      expires_at: issued_at + 1.minute
    )
    payload = JSON.parse(subscription_body("subscription_created", status: "active"))
    payload.fetch("meta")["custom_data"] = { "checkout_attempt_token" => token }

    travel_to(issued_at + 2.minutes) do
      post_signed(JSON.generate(payload))
    end

    assert_response :ok
    snapshot = Billing::WebhookEvent.order(:id).last.payload
    assert_not snapshot.keys.any? { |key| key.start_with?("checkout_") }
    assert_not_includes snapshot.to_json, token
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
      subscription_body("subscription_updated", status: "active")
    end

    def subscription_body(event_name, status:)
      JSON.generate(
        "meta" => { "event_name" => event_name },
        "data" => {
          "type" => "subscriptions",
          "id" => "sub_123",
          "attributes" => {
            "store_id" => 61_001,
            "customer_id" => 62_002,
            "product_id" => 63_003,
            "variant_id" => 64_004,
            "status" => status,
            "test_mode" => true,
            "renews_at" => "2026-08-16T00:00:00Z",
            "updated_at" => "2026-07-16T00:00:00Z",
            "user_email" => CUSTOMER_SENTINEL,
            "urls" => { "customer_portal" => "https://provider.example/signed" }
          }
        }
      )
    end

    def payment_body(event_name, invoice_id:, status:)
      JSON.generate(
        "meta" => { "event_name" => event_name },
        "data" => {
          "type" => "subscription-invoices",
          "id" => invoice_id,
          "attributes" => {
            "store_id" => 61_001,
            "subscription_id" => "sub_123",
            "customer_id" => 62_002,
            "status" => status,
            "test_mode" => true,
            "updated_at" => "2026-07-16T00:00:00Z",
            "user_email" => CUSTOMER_SENTINEL,
            "urls" => { "invoice_url" => "https://provider.example/signed" }
          }
        }
      )
    end

    def post_signed(body, secret: SECRET)
      post_raw(body, signature: signature_for(body, secret: secret))
    end

    def post_raw(body, signature:, content_type: "application/json")
      headers = { "CONTENT_TYPE" => content_type }
      headers["HTTP_X_SIGNATURE"] = signature if signature
      post lemon_squeezy_webhook_path, params: body, headers: headers
    end

    def signature_for(body, secret: SECRET)
      OpenSSL::HMAC.hexdigest("SHA256", secret, body)
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
