class Billing::SweepWebhookEventsJob < ApplicationJob
  queue_as :billing

  RECOVERY_DELAY = 1.minute
  REDISPATCH_DELAY = 6.hours

  def perform(now: Time.current)
    redispatch_before = now - REDISPATCH_DELAY
    Billing::WebhookEvent
      .status_received
      .where(received_at: ..(now - RECOVERY_DELAY))
      .where("enqueued_at IS NULL OR enqueued_at <= ?", redispatch_before)
      .find_each do |event|
        Billing::Webhooks::Enqueue.call(
          event,
          now: now,
          redispatch_before: redispatch_before
        )
      end
  end
end
