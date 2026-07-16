require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::CustomerTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "normalizes an opaque customer identifier and stays tenant owned" do
    organization, = create_billing_tenant(prefix: "customer")
    customer = create_billing_customer(
      organization: organization,
      provider_customer_id: " customer_stable "
    )

    assert_equal "customer_stable", customer.provider_customer_id
    assert_equal customer, organization.billing_customers.find(customer.id)
  end

  test "requires test mode to match the explicit provider environment" do
    organization, = create_billing_tenant(prefix: "customer-mode")
    customer = organization.billing_customers.new(
      provider: "lemon_squeezy",
      environment: "live",
      provider_customer_id: "customer_live",
      test_mode: true
    )

    assert_not customer.valid?
    assert_includes customer.errors[:test_mode], "must match the provider environment"
  end

  test "does not persist provider customer personal data" do
    assert_not_includes Billing::Customer.column_names, "email_address"
    assert_not_includes Billing::Customer.column_names, "name"
    assert_not_includes Billing::Customer.column_names, "raw_payload"
  end
end
