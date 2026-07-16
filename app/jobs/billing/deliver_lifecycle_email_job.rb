module Billing
  class DeliverLifecycleEmailJob < ApplicationJob
    class DeliveryError < StandardError; end

    MAX_ATTEMPTS = Billing::LifecycleDelivery::MAX_ATTEMPTS
    PROCESSING_LEASE = 10.minutes

    queue_as :mailers

    retry_on DeliveryError,
      wait: :polynomially_longer,
      attempts: MAX_ATTEMPTS
    retry_on ActiveRecord::Deadlocked,
      ActiveRecord::SerializationFailure,
      wait: :polynomially_longer,
      attempts: 5

    def perform(organization_id, delivery_id, now: Time.current)
      organization = Organization.find(organization_id)
      Current.organization = organization
      delivery = organization.billing_lifecycle_deliveries.find_by(id: delivery_id)
      return unless delivery
      return unless claim(delivery, now: now)

      unless eligible_recipient?(organization, delivery.recipient_user_id)
        discard(delivery, now: now, failure_code: "recipient_ineligible")
        return
      end

      Billing::LifecycleMailer
        .with(delivery_id: delivery.id)
        .public_send(delivery.kind)
        .deliver_now
      mark_delivered(delivery, now: now)
    rescue StandardError
      terminal = mark_failed(delivery) if delivery&.status_processing?
      Rails.logger.warn(
        "billing_lifecycle_delivery_failed " \
          "organization_id=#{organization_id} delivery_id=#{delivery_id}"
      )
      return if terminal

      raise DeliveryError, "billing lifecycle delivery failed", cause: nil
    ensure
      Current.reset
    end

    private
      def claim(delivery, now:)
        delivery.with_lock do
          return false if delivery.status_delivered? || delivery.status_discarded?
          return false if delivery.available_at > now
          if delivery.attempts_count >= MAX_ATTEMPTS
            exhaust(delivery, now: now)
            return false
          end
          if delivery.status_processing? && delivery.claimed_at > now - PROCESSING_LEASE
            return false
          end

          delivery.update!(
            status: "processing",
            attempts_count: delivery.attempts_count + 1,
            claimed_at: now,
            failure_code: nil
          )
        end

        true
      end

      def eligible_recipient?(organization, recipient_user_id)
        organization.organization_memberships
          .where(
            user_id: recipient_user_id,
            status: "active",
            role: Billing::LifecycleDeliveries::Record::ELIGIBLE_ROLES
          )
          .joins(:user)
          .where(users: { disabled_at: nil })
          .where.not(users: { email_verified_at: nil })
          .exists?
      end

      def mark_delivered(delivery, now:)
        delivery.with_lock do
          return if delivery.status_delivered?

          delivery.update!(
            status: "delivered",
            delivered_at: now,
            failure_code: nil
          )
        end
      end

      def mark_failed(delivery)
        delivery.with_lock do
          return if delivery.status_delivered? || delivery.status_discarded?

          if delivery.attempts_count >= MAX_ATTEMPTS
            delivery.update!(status: "discarded", failure_code: "retry_exhausted")
            true
          else
            delivery.update!(status: "failed", failure_code: "delivery_failed")
            false
          end
        end
      rescue StandardError
        Rails.logger.warn(
          "billing_lifecycle_failure_recording_failed " \
            "organization_id=#{delivery.organization_id} delivery_id=#{delivery.id}"
        )
        false
      end

      def discard(delivery, now:, failure_code:)
        delivery.with_lock do
          delivery.update!(
            status: "discarded",
            claimed_at: delivery.claimed_at || now,
            failure_code: failure_code
          )
        end
      end

      def exhaust(delivery, now:)
        return if delivery.status_delivered? || delivery.status_discarded?

        delivery.update!(
          status: "discarded",
          claimed_at: delivery.claimed_at || now,
          failure_code: "retry_exhausted"
        )
      end
  end
end
