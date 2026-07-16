module Billing
  module LifecycleDeliveries
    class Record
      ELIGIBLE_ROLES = %w[owner billing].freeze

      class << self
        def call(**arguments)
          new(**arguments).call
        end
      end

      def initialize(kind:, audit_event:, subscription:, webhook_event:, now: Time.current)
        @kind = kind.to_s
        @audit_event = audit_event
        @subscription = subscription
        @webhook_event = webhook_event
        @now = now
      end

      def call
        organization = Current.organization
        raise ArgumentError, "tenant context is required" unless organization&.persisted?
        raise ArgumentError, "unsupported lifecycle delivery kind" unless valid_kind?

        audit_event = organization.audit_events.find(@audit_event.id)
        subscription = organization.billing_subscriptions.find(@subscription.id)
        webhook_event = organization.billing_webhook_events.find(@webhook_event.id)

        eligible_recipient_ids(organization).map do |recipient_user_id|
          delivery = organization.billing_lifecycle_deliveries.create_or_find_by!(
            source_webhook_event: webhook_event,
            kind: @kind,
            recipient_user_id: recipient_user_id
          ) do |candidate|
            candidate.audit_event = audit_event
            candidate.billing_subscription = subscription
            candidate.available_at = @now
          end

          unless delivery.billing_subscription_id == subscription.id &&
              delivery.audit_event_id == audit_event.id
            raise ActiveRecord::RecordNotUnique,
              "lifecycle delivery source is already bound to another transition"
          end

          delivery
        end
      end

      private
        def valid_kind?
          Billing::LifecycleDelivery::KINDS.include?(@kind)
        end

        def eligible_recipient_ids(organization)
          organization.organization_memberships
            .where(status: "active", role: ELIGIBLE_ROLES)
            .joins(:user)
            .where(users: { disabled_at: nil })
            .where.not(users: { email_verified_at: nil })
            .order(:user_id)
            .distinct
            .pluck(:user_id)
        end
    end
  end
end
