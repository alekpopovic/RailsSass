require "test_helper"

class Billing::LemonSqueezy::SubscriptionSnapshotTest < ActiveSupport::TestCase
  SUBSCRIPTION_ID = "sub_123"
  STORE_ID = "61001"

  test "parses an allowlisted immutable subscription snapshot" do
    snapshot = parse

    assert_equal SUBSCRIPTION_ID, snapshot.provider_subscription_id
    assert_equal STORE_ID, snapshot.provider_store_id
    assert_equal "62002", snapshot.provider_customer_id
    assert_equal "63003", snapshot.provider_product_id
    assert_equal "64004", snapshot.provider_variant_id
    assert_equal "active", snapshot.status
    assert_equal "active", snapshot.provider_status
    assert_predicate snapshot, :known_status?
    assert snapshot.test_mode
    assert_equal Time.iso8601("2026-07-01T12:00:00Z"), snapshot.created_at
    assert_equal Time.iso8601("2026-07-16T12:30:45.123456Z"), snapshot.provider_updated_at
    assert_equal Time.iso8601("2026-08-16T00:00:00Z"), snapshot.renews_at
    assert_equal({}, snapshot.pause)
    assert_equal "visa", snapshot.card_brand
    assert_equal "4242", snapshot.card_last_four
    assert_predicate snapshot, :frozen?
    assert_predicate snapshot.pause, :frozen?
  end

  test "exposes only sanitized and critical equality data" do
    payload = valid_payload
    payload["data"]["attributes"].merge!(
      "user_email" => "private-customer@example.test",
      "user_name" => "Private Customer",
      "urls" => { "customer_portal" => "https://provider.test/signed?signature=private" }
    )
    payload["meta"] = {
      "custom_data" => { "checkout_attempt_token" => "private-signed-token" }
    }

    snapshot = parse(payload:)
    serialized = snapshot.to_h.to_json

    assert_equal "subscription_updated",
      snapshot.sanitized_payload(event_name: "subscription_updated").fetch("event_name")
    assert_equal "active", snapshot.critical_attributes.fetch("status")
    assert_equal "2026-07-01T12:00:00.000000Z",
      snapshot.critical_attributes.fetch("provider_created_at")
    assert_not_includes serialized, "private-customer@example.test"
    assert_not_includes serialized, "Private Customer"
    assert_not_includes serialized, "customer_portal"
    assert_not_includes serialized, "private-signed-token"
    assert_not_includes serialized, "signature"

    assert_raises(described_class::ParseError) do
      snapshot.sanitized_payload(event_name: "Invalid Event")
    end
  end

  test "normalizes a bounded unknown status to fail closed without losing equality data" do
    payload = valid_payload
    payload["data"]["attributes"]["status"] = "provider_future_state"

    snapshot = parse(payload:)

    assert_equal "unknown", snapshot.status
    assert_equal "provider_future_state", snapshot.provider_status
    assert_not_predicate snapshot, :known_status?
    assert_equal "unknown", snapshot.critical_attributes.fetch("status")

    payload["data"]["attributes"]["ends_at"] = "2026-08-16T00:00:00Z"
    assert_equal Time.iso8601("2026-08-16T00:00:00Z"), parse(payload:).ends_at
  end

  test "rejects malformed envelopes and provider identities" do
    mutations = [
      ->(payload) { payload.delete("data") },
      ->(payload) { payload["data"]["type"] = "orders" },
      ->(payload) { payload["data"]["id"] = "sub/unsafe" },
      ->(payload) { payload["data"]["id"] = "sub_other" },
      ->(payload) { payload["data"].delete("attributes") },
      ->(payload) { payload["data"]["attributes"]["store_id"] = 61_002 },
      ->(payload) { payload["data"]["attributes"]["customer_id"] = 0 },
      ->(payload) { payload["data"]["attributes"]["product_id"] = "063003" },
      ->(payload) { payload["data"]["attributes"]["variant_id"] = [] },
      ->(payload) { payload["data"]["attributes"]["test_mode"] = "true" },
      ->(payload) { payload["data"]["attributes"]["status"] = "ACTIVE" },
      ->(payload) { payload["data"]["attributes"]["status"] = "x" * 65 }
    ]

    mutations.each do |mutation|
      payload = valid_payload
      mutation.call(payload)
      assert_parse_error(payload:)
    end

    assert_parse_error(payload: [])
    assert_parse_error(expected_store_id: "not-numeric")
    assert_parse_error(expected_test_mode: nil)
  end

  test "requires strict and internally ordered ISO 8601 timestamps" do
    mutations = [
      ->(attributes) { attributes["created_at"] = nil },
      ->(attributes) { attributes["created_at"] = "2026-07-01" },
      ->(attributes) { attributes["updated_at"] = "2026-07-16T12:30:45" },
      ->(attributes) { attributes["updated_at"] = "2026-13-16T12:30:45Z" },
      ->(attributes) { attributes["updated_at"] = "2026-06-30T12:00:00Z" },
      ->(attributes) { attributes["renews_at"] = "2026-06-30T12:00:00Z" },
      ->(attributes) { attributes["trial_ends_at"] = 123 },
      ->(attributes) { attributes["ends_at"] = "2026-08-16T00:00:00Z" },
      lambda do |attributes|
        attributes["status"] = "on_trial"
        attributes["trial_ends_at"] = nil
      end,
      lambda do |attributes|
        attributes["status"] = "cancelled"
        attributes["ends_at"] = nil
      end,
      lambda do |attributes|
        attributes["status"] = "expired"
        attributes["ends_at"] = nil
      end
    ]

    mutations.each do |mutation|
      payload = valid_payload
      mutation.call(payload["data"]["attributes"])
      assert_parse_error(payload:)
    end

    payload = valid_payload
    attributes = payload["data"]["attributes"]
    attributes["status"] = "cancelled"
    attributes["renews_at"] = nil
    attributes["ends_at"] = "2026-08-16T00:00:00+02:00"
    snapshot = parse(payload:)
    assert_equal Time.iso8601("2026-08-15T22:00:00Z"), snapshot.ends_at
  end

  test "accepts only bounded pause and consistent card display fields" do
    payload = valid_payload
    payload["data"]["attributes"]["pause"] = {
      "mode" => "void",
      "resumes_at" => "2026-08-01T00:00:00Z"
    }
    snapshot = parse(payload:)
    assert_equal(
      { "mode" => "void", "resumes_at" => "2026-08-01T00:00:00.000000Z" },
      snapshot.pause
    )

    non_card_payload = valid_payload
    non_card_payload["data"]["attributes"].merge!(
      "card_brand" => "",
      "card_last_four" => ""
    )
    non_card_snapshot = parse(payload: non_card_payload)
    assert_nil non_card_snapshot.card_brand
    assert_nil non_card_snapshot.card_last_four

    mutations = [
      ->(attributes) { attributes["pause"] = [] },
      ->(attributes) { attributes["pause"] = {} },
      ->(attributes) { attributes["pause"] = { "mode" => "unknown" } },
      ->(attributes) { attributes["pause"] = { "mode" => "void", "private" => "value" } },
      lambda do |attributes|
        attributes["pause"] = { "mode" => "free", "resumes_at" => "tomorrow" }
      end,
      ->(attributes) { attributes["card_last_four"] = nil },
      ->(attributes) { attributes["card_brand"] = nil },
      ->(attributes) { attributes["card_brand"] = " visa " },
      ->(attributes) { attributes["card_brand"] = "visa\nsecret" },
      ->(attributes) { attributes["card_last_four"] = "42x2" }
    ]

    mutations.each do |mutation|
      invalid_payload = valid_payload
      mutation.call(invalid_payload["data"]["attributes"])
      assert_parse_error(payload: invalid_payload)
    end
  end

  private
    def described_class
      Billing::LemonSqueezy::SubscriptionSnapshot
    end

    def parse(
      payload: valid_payload,
      expected_subscription_id: SUBSCRIPTION_ID,
      expected_store_id: STORE_ID,
      expected_test_mode: true
    )
      described_class.parse(
        payload:,
        expected_subscription_id:,
        expected_store_id:,
        expected_test_mode:
      )
    end

    def assert_parse_error(**attributes)
      error = assert_raises(described_class::ParseError) { parse(**attributes) }
      assert_equal 200, error.status
      assert_not error.retryable?
      assert_nil error.cause
    end

    def valid_payload
      {
        "jsonapi" => { "version" => "1.0" },
        "data" => {
          "type" => "subscriptions",
          "id" => SUBSCRIPTION_ID,
          "attributes" => {
            "store_id" => 61_001,
            "customer_id" => 62_002,
            "product_id" => 63_003,
            "variant_id" => 64_004,
            "status" => "active",
            "card_brand" => "visa",
            "card_last_four" => "4242",
            "pause" => nil,
            "trial_ends_at" => nil,
            "renews_at" => "2026-08-16T00:00:00Z",
            "ends_at" => nil,
            "created_at" => "2026-07-01T12:00:00Z",
            "updated_at" => "2026-07-16T12:30:45.123456Z",
            "test_mode" => true
          }
        }
      }
    end
end
