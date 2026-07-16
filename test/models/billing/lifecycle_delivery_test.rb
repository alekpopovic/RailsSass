require "test_helper"
require_relative "../../support/billing_lifecycle_delivery_test_helper"

class Billing::LifecycleDeliveryTest < ActiveSupport::TestCase
  include BillingLifecycleDeliveryTestHelper

  teardown { Current.reset }

  test "requires a valid append-only identity and consistent lifecycle state" do
    _, _, _, _, _, delivery = create_lifecycle_delivery_context

    delivery.assign_attributes(status: "delivered", delivered_at: Time.current)
    assert_not delivery.valid?
    assert_includes delivery.errors[:claimed_at], "must be present"

    delivery.reload
    delivery.assign_attributes(status: "failed", claimed_at: Time.current)
    assert_not delivery.valid?
    assert_includes delivery.errors[:failure_code], "must be present"

    delivery.reload
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      delivery.kind = "raw_payload"
    end
  end

  test "does not permit identity reassignment after persistence" do
    organization, _, _, _, _, delivery = create_lifecycle_delivery_context
    original_kind = delivery.kind
    original_recipient_id = delivery.recipient_user_id
    another_user = create_test_user(
      email_address: "lifecycle-identity-#{SecureRandom.hex(4)}@example.test"
    )
    create_test_membership(
      organization: organization,
      user: another_user,
      role: :billing
    )

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      delivery.update!(kind: "payment_problem", recipient_user: another_user)
    end

    assert_equal original_kind, delivery.reload.kind
    assert_equal original_recipient_id, delivery.recipient_user_id
  end
end
