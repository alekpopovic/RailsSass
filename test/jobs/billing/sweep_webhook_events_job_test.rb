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

  test "processing job receives only the global receipt id and does not mutate billing state" do
    now = Time.current
    event = create_billing_webhook_event(
      received_at: now - 1.second,
      verified_at: now - 1.second,
      enqueued_at: now
    )

    assert_no_difference -> { Billing::Subscription.count } do
      Billing::ProcessWebhookJob.perform_now(event.id)
    end

    assert_predicate event.reload, :status_received?
    assert_nil event.processing_started_at
    assert_nil event.processed_at
  end
end
