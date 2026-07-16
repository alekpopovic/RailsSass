class Billing::SweepWebhookEventsJob < ApplicationJob
  queue_as :billing

  RECOVERY_DELAY = 1.minute
  REDISPATCH_DELAY = 6.hours
  PROCESSING_LEASE = Billing::Webhooks::Processor::PROCESSING_LEASE

  def perform(now: Time.current)
    redispatch_before = now - REDISPATCH_DELAY
    Billing::WebhookEvent
      .status_received
      .where(ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION)
      .where(received_at: ..(now - RECOVERY_DELAY))
      .where("enqueued_at IS NULL OR enqueued_at <= ?", redispatch_before)
      .find_each do |event|
        Billing::Webhooks::Enqueue.call(
          event,
          now: now,
          redispatch_before: redispatch_before
        )
      end

    Billing::WebhookEvent
      .status_processing
      .where(ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION)
      .where(processing_started_at: ..(now - PROCESSING_LEASE))
      .find_each do |event|
        Billing::ProcessWebhookJob.perform_later(event.id)
      end

    Billing::WebhookEvent
      .status_failed
      .where(ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION)
      .where(error_code: Billing::Webhooks::Processor::RETRYABLE_ERROR_CODES)
      .where("attempts_count < ?", Billing::Webhooks::Processor::MAX_PROCESSING_ATTEMPTS)
      .where(failed_at: ..(now - REDISPATCH_DELAY))
      .find_each do |event|
        Billing::ProcessWebhookJob.perform_later(event.id)
      end
  end
end
