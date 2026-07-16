require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::SweepWebhookEventsJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include BillingTestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "recovers a durable receipt whose initial enqueue failed" do
    now = Time.current
    event = create_billing_webhook_event(received_at: now - 2.minutes, verified_at: now - 2.minutes)

    assert_enqueued_with(job: Billing::ProcessWebhookJob, args: [ event.id ], queue: "billing") do
      Billing::SweepWebhookEventsJob.perform_now(now: now)
    end

    assert_equal now.to_i, event.reload.enqueued_at.to_i
    assert_predicate event, :status_received?
  end

  test "does not enqueue recent or already handed-off receipts" do
    now = Time.current
    create_billing_webhook_event(received_at: now, verified_at: now)
    create_billing_webhook_event(
      received_at: now - 2.minutes,
      verified_at: now - 2.minutes,
      enqueued_at: now - 1.minute
    )

    assert_no_enqueued_jobs do
      Billing::SweepWebhookEventsJob.perform_now(now: now)
    end
  end

  test "does not enqueue legacy rows without current signed-ingress provenance" do
    now = Time.current
    event = create_billing_webhook_event(
      received_at: now - 2.minutes,
      verified_at: now - 2.minutes,
      ingress_version: nil
    )

    assert_no_enqueued_jobs do
      Billing::SweepWebhookEventsJob.perform_now(now: now)
    end
  end

  test "redispatches a stale received receipt so a later processor release can claim it" do
    now = Time.current
    event = create_billing_webhook_event(
      received_at: now - 8.hours,
      verified_at: now - 8.hours,
      enqueued_at: now - 7.hours
    )

    assert_enqueued_with(job: Billing::ProcessWebhookJob, args: [ event.id ], queue: "billing") do
      Billing::SweepWebhookEventsJob.perform_now(now: now)
    end

    assert_equal now.to_i, event.reload.enqueued_at.to_i
    assert_predicate event, :status_received?
  end

  test "processing job delegates the durable receipt id and its actual job id" do
    now = Time.current
    event = create_billing_webhook_event(
      received_at: now - 1.second,
      verified_at: now - 1.second,
      enqueued_at: now
    )

    calls = []
    processor = lambda do |**attributes|
      calls << attributes
      Billing::Webhooks::Processor::Result.new(
        status: :noop,
        event: event,
        subscription: nil
      )
    end

    original_call = Billing::Webhooks::Processor.method(:call)
    Billing::Webhooks::Processor.define_singleton_method(:call, processor)
    job = Billing::ProcessWebhookJob.new(event.id)
    begin
      job.perform_now
    ensure
      Billing::Webhooks::Processor.define_singleton_method(:call, original_call)
    end

    assert_equal [ { webhook_event_id: event.id, job_id: job.job_id } ], calls
  end

  test "sweeper redispatches abandoned processing and recoverable failed events" do
    now = Time.current
    processing_event = create_billing_webhook_event(
      status: :processing,
      received_at: now - 8.hours,
      verified_at: now - 8.hours,
      processing_started_at: now - Billing::Webhooks::Processor::PROCESSING_LEASE - 1.second,
      attempt_count: 1
    )
    failed_event = create_billing_webhook_event(
      status: :failed,
      received_at: now - 8.hours,
      verified_at: now - 8.hours,
      processing_started_at: now - 8.hours,
      processed_at: now - 7.hours,
      failed_at: now - 7.hours,
      error_code: "provider_temporarily_unavailable",
      attempt_count: 1,
      snapshot: { "reason_code" => "provider_temporarily_unavailable" }
    )

    assert_enqueued_with(job: Billing::ProcessWebhookJob, args: [ processing_event.id ]) do
      assert_enqueued_with(job: Billing::ProcessWebhookJob, args: [ failed_event.id ]) do
        Billing::SweepWebhookEventsJob.perform_now(now: now)
      end
    end
  end
end
