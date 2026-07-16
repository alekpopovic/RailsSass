module Billing
  module LifecycleDeliveries
    class Enqueue
      class << self
        def call(**arguments)
          new(**arguments).call
        end
      end

      def initialize(delivery_id:, now: Time.current, redispatch_before: nil)
        @delivery_id = delivery_id
        @now = now
        @redispatch_before = redispatch_before
      end

      def call
        organization = Current.organization
        raise ArgumentError, "tenant context is required" unless organization&.persisted?

        delivery = organization.billing_lifecycle_deliveries.find(@delivery_id)
        return true if delivery.status_delivered? || delivery.status_discarded?
        return true if delivery.attempts_count >= Billing::LifecycleDelivery::MAX_ATTEMPTS

        claimed = claim_enqueue_slot(organization)
        return true unless claimed

        enqueue_job(organization, delivery)
      end

      private
        def claim_enqueue_slot(organization)
          scope = organization.billing_lifecycle_deliveries
            .where(id: @delivery_id)
            .where("attempts_count < ?", Billing::LifecycleDelivery::MAX_ATTEMPTS)
            .where(available_at: ..@now)

          if @redispatch_before
            scope = scope.where(
              <<~SQL.squish,
                status IN ('pending', 'failed')
                OR (status = 'processing' AND claimed_at <= :redispatch_before)
              SQL
              redispatch_before: @redispatch_before
            ).where("enqueued_at IS NULL OR enqueued_at <= ?", @redispatch_before)
          else
            scope = scope.where(status: %w[pending failed], enqueued_at: nil)
          end

          scope.update_all(enqueued_at: @now, updated_at: @now) == 1
        end

        def release_enqueue_slot(organization)
          organization.billing_lifecycle_deliveries
            .where(id: @delivery_id, enqueued_at: @now)
            .update_all(enqueued_at: nil, updated_at: Time.current)
        end

        def enqueue_job(organization, delivery)
          job = Billing::DeliverLifecycleEmailJob.perform_later(organization.id, delivery.id)
          return true if job&.successfully_enqueued?

          enqueue_failed(organization)
        rescue StandardError
          enqueue_failed(organization)
        end

        def enqueue_failed(organization)
          release_enqueue_slot(organization)
          Rails.logger.warn(
            "billing_lifecycle_enqueue_failed " \
              "organization_id=#{organization.id} delivery_id=#{@delivery_id}"
          )
          false
        end
    end
  end
end
