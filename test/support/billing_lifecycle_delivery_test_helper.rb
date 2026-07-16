require_relative "billing_test_helper"

module BillingLifecycleDeliveryTestHelper
  include BillingTestHelper

  def create_lifecycle_delivery_context(kind: "subscription_activated", recipient_membership: nil)
    organization, owner_membership = create_billing_tenant(prefix: "lifecycle")
    subscription = create_billing_subscription(organization: organization)
    webhook_event = create_billing_webhook_event(organization: organization)
    Current.organization = organization
    audit_event = AuditEvents::Record.call(
      organization: organization,
      actor_user: nil,
      action: "billing.subscription.updated",
      subject: subscription
    )
    recipient_membership ||= owner_membership
    delivery = organization.billing_lifecycle_deliveries.create!(
      audit_event: audit_event,
      billing_subscription: subscription,
      source_webhook_event: webhook_event,
      recipient_user: recipient_membership.user,
      kind: kind,
      available_at: Time.current
    )

    [ organization, owner_membership, subscription, webhook_event, audit_event, delivery ]
  ensure
    Current.reset
  end
end
