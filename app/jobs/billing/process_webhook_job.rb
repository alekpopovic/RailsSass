class Billing::ProcessWebhookJob < ApplicationJob
  queue_as :billing

  # This ingress milestone hands a durable receipt to Solid Queue. Subscription
  # projection remains a separate, idempotent worker milestone; leaving the row
  # in `received` preserves the verified authority until that processor claims
  # it. The sweeper redispatches stale receipts so a later worker release can
  # claim events accepted before projection exists.
  def perform(webhook_event_id)
    Billing::WebhookEvent.find(webhook_event_id)
  end
end
