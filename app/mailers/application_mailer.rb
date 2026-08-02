class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAILER_FROM", "no-reply@example.test") }
  layout "mailer"

  class << self
    # Rails includes the complete encoded message and recipient metadata in the
    # default delivery notification. Keep delivery observability without
    # publishing tokens, signed links, or addresses to instrumentation subscribers.
    def deliver_mail(mail)
      ActiveSupport::Notifications.instrument("deliver.action_mailer") do |payload|
        payload[:mail] = "[FILTERED]"
        payload[:mailer] = name
        payload[:message_id] = mail.message_id
        payload[:perform_deliveries] = mail.perform_deliveries
        yield
      end
    end
  end
end
