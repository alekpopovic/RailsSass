module Billing
  module Webhooks
    class Enqueue
      class << self
        def call(event, now: Time.current, redispatch_before: nil)
          event.with_lock do
            return true unless event.status_received?
            if event.enqueued_at?
              return true unless redispatch_before && event.enqueued_at <= redispatch_before
            end

            job = Billing::ProcessWebhookJob.perform_later(event.id)
            return enqueue_failed(event) unless job&.successfully_enqueued?

            event.update!(enqueued_at: now)
          end

          true
        rescue StandardError
          enqueue_failed(event)
        end

        private
          def enqueue_failed(event)
            Rails.logger.warn("billing_webhook_enqueue_failed event_id=#{event.id}")
            false
          end
      end
    end
  end
end
