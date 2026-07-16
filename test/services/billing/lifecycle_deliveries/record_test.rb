require "test_helper"
require_relative "../../../support/billing_lifecycle_delivery_test_helper"

class Billing::LifecycleDeliveries::RecordTest < ActiveSupport::TestCase
  include BillingLifecycleDeliveryTestHelper

  teardown { Current.reset }

  test "records one idempotent delivery for each active verified owner or billing member" do
    organization, owner_membership = create_billing_tenant(prefix: "lifecycle-recipients")
    billing = add_member(organization, role: :billing, label: "billing")
    add_member(organization, role: :admin, label: "admin")
    add_member(organization, role: :member, label: "member")
    add_member(organization, role: :billing, label: "unverified", verified: false)
    add_member(organization, role: :owner, label: "disabled", disabled_at: Time.current)
    suspended = add_member(organization, role: :billing, label: "suspended")
    organization.organization_memberships
      .where(id: suspended.id)
      .update_all(status: "suspended", updated_at: Time.current)
    subscription, webhook_event, audit_event = billing_source(organization)
    Current.organization = organization

    first = Billing::LifecycleDeliveries::Record.call(
      kind: :subscription_activated,
      audit_event: audit_event,
      subscription: subscription,
      webhook_event: webhook_event
    )
    second = Billing::LifecycleDeliveries::Record.call(
      kind: :subscription_activated,
      audit_event: audit_event,
      subscription: subscription,
      webhook_event: webhook_event
    )

    assert_equal [ owner_membership.user_id, billing.user_id ].sort,
      first.map(&:recipient_user_id).sort
    assert_equal first.map(&:id).sort, second.map(&:id).sort
    assert_equal 2, organization.billing_lifecycle_deliveries.count
  end

  test "fails closed without tenant context or for a cross-tenant source" do
    organization, = create_billing_tenant(prefix: "lifecycle-local")
    subscription, webhook_event, audit_event = billing_source(organization)
    foreign_organization, = create_billing_tenant(prefix: "lifecycle-foreign")
    foreign_subscription = create_billing_subscription(organization: foreign_organization)

    Current.reset
    assert_raises(ArgumentError) do
      Billing::LifecycleDeliveries::Record.call(
        kind: :subscription_activated,
        audit_event: audit_event,
        subscription: subscription,
        webhook_event: webhook_event
      )
    end

    Current.organization = organization
    assert_raises(ActiveRecord::RecordNotFound) do
      Billing::LifecycleDeliveries::Record.call(
        kind: :subscription_activated,
        audit_event: audit_event,
        subscription: foreign_subscription,
        webhook_event: webhook_event
      )
    end
  end

  test "does not silently rebind a duplicate delivery to another audit transition" do
    organization, = create_billing_tenant(prefix: "lifecycle-audit-binding")
    subscription, webhook_event, first_audit_event = billing_source(organization)
    Current.organization = organization
    Billing::LifecycleDeliveries::Record.call(
      kind: :subscription_activated,
      audit_event: first_audit_event,
      subscription: subscription,
      webhook_event: webhook_event
    )
    second_audit_event = AuditEvents::Record.call(
      organization: organization,
      actor_user: nil,
      action: "billing.subscription.updated",
      subject: subscription
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      Billing::LifecycleDeliveries::Record.call(
        kind: :subscription_activated,
        audit_event: second_audit_event,
        subscription: subscription,
        webhook_event: webhook_event
      )
    end
  end

  private
    def add_member(organization, role:, label:, verified: true, disabled_at: nil)
      user = create_test_user(
        email_address: "#{label}-#{SecureRandom.hex(6)}@example.test",
        verified: verified,
        disabled_at: disabled_at
      )
      create_test_membership(organization: organization, user: user, role: role)
    end

    def billing_source(organization)
      subscription = create_billing_subscription(organization: organization)
      webhook_event = create_billing_webhook_event(organization: organization)
      Current.organization = organization
      audit_event = AuditEvents::Record.call(
        organization: organization,
        actor_user: nil,
        action: "billing.subscription.updated",
        subject: subscription
      )
      [ subscription, webhook_event, audit_event ]
    end
end
