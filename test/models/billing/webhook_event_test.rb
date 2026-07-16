require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::WebhookEventTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "is a provider-wide idempotency ledger with optional resolved tenant" do
    event = create_billing_webhook_event(
      provider_event_id: "provider_event_123",
      event_name: "subscription_updated"
    )

    assert_nil event.organization
    assert_match(/\A[0-9a-f]{64}\z/, event.fingerprint)
    assert_equal event.fingerprint, event.body_sha256
    assert_equal "provider_event_123", event.provider_event_id
    assert_equal event.snapshot, event.payload
    assert_equal event.attempt_count, event.attempts_count
    assert_predicate event, :status_received?
  end

  test "rejects sensitive snapshots and inconsistent processing lifecycle" do
    now = Time.current
    event = Billing::WebhookEvent.new(
      provider: "lemon_squeezy",
      environment: "test",
      fingerprint: Digest::SHA256.hexdigest("sensitive-event"),
      status: "processed",
      test_mode: true,
      received_at: now,
      verified_at: now,
      snapshot: { "authorization" => "Bearer private" }
    )

    assert_not event.valid?
    assert_includes event.errors[:processed_at], "must be present"
    assert_includes event.errors[:snapshot], "contains a sensitive field"

    event.snapshot = { "contact" => "private@example.test" }
    assert_not event.valid?
    assert_includes event.errors[:snapshot], "contains an unsupported field"
  end

  test "keeps requested ingress fields compatible with the existing ledger interface" do
    event = create_billing_webhook_event(
      external_resource_type: "subscriptions",
      external_resource_id: "subscription_123",
      payload: { "resource_type" => "subscriptions" },
      attempts_count: 2
    )

    assert_equal "subscription_123", event.provider_resource_id
    assert_equal event.payload, event.snapshot
    assert_equal 2, event.attempt_count

    event.payload = { "event_name" => "subscription_updated" }
    event.snapshot = { "event_name" => "subscription_created" }
    assert_not event.valid?
    assert_includes event.errors[:payload], "must match the sanitized snapshot"
  end
end
