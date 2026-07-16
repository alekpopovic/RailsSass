class Billing::ProcessWebhookJob < ApplicationJob
  queue_as :billing

  retry_on Billing::Webhooks::Processor::RetryableError,
    wait: :polynomially_longer,
    attempts: 8
  retry_on ActiveRecord::Deadlocked,
    ActiveRecord::SerializationFailure,
    wait: :polynomially_longer,
    attempts: 5

  def perform(webhook_event_id)
    Billing::Webhooks::Processor.call(webhook_event_id: webhook_event_id)
  end
end
