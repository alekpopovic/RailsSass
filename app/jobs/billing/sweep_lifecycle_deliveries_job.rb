module Billing
  class SweepLifecycleDeliveriesJob < ApplicationJob
    queue_as :billing

    REDISPATCH_DELAY = Billing::DeliverLifecycleEmailJob::PROCESSING_LEASE

    def perform(now: Time.current)
      Organization.find_each do |organization|
        Current.organization = organization
        redispatch_before = now - REDISPATCH_DELAY

        organization.billing_lifecycle_deliveries
          .where(status: %w[pending failed])
          .where("attempts_count < ?", Billing::LifecycleDelivery::MAX_ATTEMPTS)
          .where(available_at: ..now)
          .where("enqueued_at IS NULL OR enqueued_at <= ?", redispatch_before)
          .find_each do |delivery|
            Billing::LifecycleDeliveries::Enqueue.call(
              delivery_id: delivery.id,
              now: now,
              redispatch_before: redispatch_before
            )
          end

        organization.billing_lifecycle_deliveries
          .where(status: "processing")
          .where("attempts_count < ?", Billing::LifecycleDelivery::MAX_ATTEMPTS)
          .where(claimed_at: ..redispatch_before)
          .where("enqueued_at IS NULL OR enqueued_at <= ?", redispatch_before)
          .find_each do |delivery|
            Billing::LifecycleDeliveries::Enqueue.call(
              delivery_id: delivery.id,
              now: now,
              redispatch_before: redispatch_before
            )
          end
      ensure
        Current.reset
      end
    ensure
      Current.reset
    end
  end
end
