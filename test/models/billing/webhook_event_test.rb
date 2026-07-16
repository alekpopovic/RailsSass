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
    assert_equal "provider_event_123", event.provider_event_id
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
end
