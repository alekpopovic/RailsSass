module Billing
  class LifecycleMailer < ApplicationMailer
    SUBJECTS = {
      "subscription_activated" => "Subscription activated",
      "payment_problem" => "Payment problem",
      "cancellation_scheduled" => "Subscription cancellation scheduled",
      "subscription_expired" => "Subscription expired",
      "plan_change_completed" => "Plan change completed"
    }.freeze

    before_action :load_delivery

    Billing::LifecycleDelivery::KINDS.each do |delivery_kind|
      define_method(delivery_kind) do
        deliver_lifecycle_message(delivery_kind)
      end
    end

    private
      def load_delivery
        organization = Current.organization
        raise ArgumentError, "tenant context is required" unless organization&.persisted?

        @delivery = organization.billing_lifecycle_deliveries
          .includes(:recipient_user, billing_subscription: { plan_price: :plan })
          .find(params.fetch(:delivery_id))
        @organization = organization
        @recipient = @delivery.recipient_user
        @subscription = @delivery.billing_subscription
        @plan = @subscription.plan_price.plan
        @billing_url = organization_billing_url(organization_slug: organization.slug)
      end

      def deliver_lifecycle_message(delivery_kind)
        mail(
          to: @recipient.email_address,
          subject: "#{SUBJECTS.fetch(delivery_kind)} for #{@organization.name}",
          message_id: deterministic_message_id
        )
      end

      def deterministic_message_id
        "<billing-lifecycle-#{@delivery.id}@#{message_id_host}>"
      end

      def message_id_host
        configured_host = Rails.application.config.action_mailer
          .default_url_options
          .fetch(:host, "example.test")
          .to_s
          .downcase
        configured_host.match?(/\A[a-z0-9.-]+\z/) ? configured_host : "example.test"
      end
  end
end
