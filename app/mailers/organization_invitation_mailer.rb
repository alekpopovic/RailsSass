class OrganizationInvitationMailer < ApplicationMailer
  class DeliveryContext < ActiveSupport::CurrentAttributes
    attribute :invitation, :raw_token
  end

  class << self
    def deliver_invitation!(invitation:, raw_token:)
      validate_delivery!(invitation, raw_token)

      DeliveryContext.set(invitation: invitation, raw_token: raw_token) do
        self.invitation.deliver_now
      end
    end

    # Rails' default delivery notification contains the complete encoded mail.
    # Keep observability without publishing the invitation link to subscribers.
    def deliver_mail(mail)
      ActiveSupport::Notifications.instrument("deliver.action_mailer") do |payload|
        payload[:mail] = "[FILTERED]"
        payload[:mailer] = name
        payload[:message_id] = mail.message_id
        payload[:perform_deliveries] = mail.perform_deliveries
        yield
      end
    end

    private
      def validate_delivery!(invitation, raw_token)
        valid = invitation&.persisted? && raw_token.present? &&
          invitation.token_digest == OrganizationInvitation.digest_token(raw_token)
        raise ArgumentError, "invitation delivery context is invalid" unless valid
      end
  end

  def invitation
    @invitation = DeliveryContext.invitation
    @organization = @invitation.organization
    @inviter = @invitation.inviter
    @acceptance_url = organization_invitation_acceptance_url(
      organization_slug: @organization.slug,
      token: DeliveryContext.raw_token
    )

    mail to: @invitation.email_address, subject: "You're invited to #{@organization.name}"
  end
end
