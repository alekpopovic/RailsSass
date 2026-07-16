require "test_helper"
require_relative "../../support/billing_lifecycle_delivery_test_helper"

class Billing::LifecycleMailerTest < ActionMailer::TestCase
  include BillingLifecycleDeliveryTestHelper

  teardown { Current.reset }

  test "renders every lifecycle message without provider identifiers" do
    organization, _, subscription, webhook_event, audit_event, first_delivery =
      create_lifecycle_delivery_context
    Current.organization = organization
    deliveries = Billing::LifecycleDelivery::KINDS.map do |kind|
      if kind == first_delivery.kind
        first_delivery
      else
        organization.billing_lifecycle_deliveries.create!(
          audit_event: audit_event,
          billing_subscription: subscription,
          source_webhook_event: webhook_event,
          recipient_user: first_delivery.recipient_user,
          kind: kind,
          available_at: Time.current
        )
      end
    end

    deliveries.each do |delivery|
      email = Billing::LifecycleMailer
        .with(delivery_id: delivery.id)
        .public_send(delivery.kind)

      assert_equal [ delivery.recipient_user.email_address ], email.to
      assert_includes email.subject, organization.name
      assert_equal "billing-lifecycle-#{delivery.id}@example.com", email.message_id
      assert_predicate email, :multipart?
      assert_includes email.html_part.body.to_s, organization.name
      assert_includes email.text_part.body.to_s, organization.name
      assert_not_includes email.body.to_s, subscription.provider_subscription_id
      assert_not_includes email.body.to_s, webhook_event.fingerprint
    end
  end

  test "filters the encoded email from delivery instrumentation" do
    organization, _, _, _, _, delivery = create_lifecycle_delivery_context
    Current.organization = organization
    payloads = []
    subscription = ActiveSupport::Notifications.subscribe("deliver.action_mailer") do |event|
      payloads << event.payload
    end

    Billing::LifecycleMailer
      .with(delivery_id: delivery.id)
      .subscription_activated
      .deliver_now

    assert_equal [ "[FILTERED]" ], payloads.map { |payload| payload.fetch(:mail) }
    assert_equal [ "Billing::LifecycleMailer" ], payloads.map { |payload| payload.fetch(:mailer) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
