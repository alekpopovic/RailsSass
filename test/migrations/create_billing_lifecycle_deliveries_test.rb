require "test_helper"

class CreateBillingLifecycleDeliveriesTest < ActiveSupport::TestCase
  test "installs constrained outbox columns and recovery indexes" do
    columns = Billing::LifecycleDelivery.columns_hash
    required = %w[
      organization_id audit_event_id billing_subscription_id source_webhook_event_id
      recipient_user_id kind status attempts_count available_at created_at updated_at
    ]
    required.each do |name|
      assert_not columns.fetch(name).null, "expected #{name} to be NOT NULL"
    end

    %w[enqueued_at claimed_at delivered_at failure_code].each do |name|
      assert_predicate columns.fetch(name), :null
    end

    indexes = Billing::LifecycleDelivery.connection
      .indexes(:billing_lifecycle_deliveries)
      .index_by(&:name)
    dedupe = indexes.fetch("index_billing_lifecycle_deliveries_on_dedupe_identity")
    assert_predicate dedupe, :unique
    assert_equal %w[source_webhook_event_id kind recipient_user_id], dedupe.columns
    assert indexes.key?("index_billing_lifecycle_deliveries_on_tenant_recovery")
    assert indexes.key?("index_billing_lifecycle_deliveries_on_processing_lease")
  end

  test "binds every referenced tenant record and recipient membership to one organization" do
    foreign_keys = Billing::LifecycleDelivery.connection
      .foreign_keys(:billing_lifecycle_deliveries)
      .index_by(&:name)

    assert_equal %w[audit_event_id organization_id],
      foreign_keys.fetch("fk_billing_lifecycle_deliveries_audit_tenant").column
    assert_equal %w[billing_subscription_id organization_id],
      foreign_keys.fetch("fk_billing_lifecycle_deliveries_subscription_tenant").column
    assert_equal %w[source_webhook_event_id organization_id],
      foreign_keys.fetch("fk_billing_lifecycle_deliveries_webhook_tenant").column
    assert_equal %w[organization_id recipient_user_id],
      foreign_keys.fetch("fk_billing_lifecycle_deliveries_recipient_membership").column
    assert foreign_keys.values.all? { |foreign_key| foreign_key.on_delete == :restrict }
  end

  test "installs database lifecycle and allowlist checks" do
    constraints = Billing::LifecycleDelivery.connection
      .check_constraints(:billing_lifecycle_deliveries)
      .index_by(&:name)

    %w[
      billing_lifecycle_deliveries_kind_allowed
      billing_lifecycle_deliveries_status_allowed
      billing_lifecycle_deliveries_attempts_non_negative
      billing_lifecycle_deliveries_lifecycle
      billing_lifecycle_deliveries_failure_code_normalized
    ].each { |name| assert constraints.key?(name), "missing #{name}" }
  end
end
