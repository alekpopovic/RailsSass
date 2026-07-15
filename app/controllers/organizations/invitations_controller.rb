class Organizations::InvitationsController < Organizations::BaseController
  rate_limit to: 10, within: 1.hour, only: :create, name: "organization-invitation-create",
    by: -> { "#{Current.user.id}:#{Current.organization.id}" },
    with: -> { redirect_to_members_with_rate_limit }
  rate_limit to: 10, within: 1.hour, only: :resend, name: "organization-invitation-resend",
    by: -> { "#{Current.user.id}:#{Current.organization.id}" },
    with: -> { redirect_to_members_with_rate_limit }

  before_action :set_invitation, only: %i[resend revoke]

  def new
    @invitation = Current.organization.organization_invitations.new
    authorize @invitation, :new?
  end

  def create
    @invitation = Current.organization.organization_invitations.new(invitation_params)
    authorize @invitation, :create?

    result = Organizations::Invitations::Create.new(
      actor: Current.user,
      email_address: invitation_params[:email_address],
      organization_role: invitation_params[:organization_role]
    ).call
    deliver_invitation(result)

    notice = result.deliver? ? "Invitation sent." : "An active invitation is already pending."
    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      notice: notice
  rescue ActiveRecord::RecordInvalid => error
    raise unless error.record.is_a?(OrganizationInvitation)

    @invitation = error.record
    render :new, status: :unprocessable_content
  end

  def resend
    authorize @invitation, :resend?
    result = Organizations::Invitations::Resend.new(
      actor: Current.user,
      invitation_id: @invitation.id
    ).call
    deliver_invitation(result)

    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      notice: "Invitation resent."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      alert: error.record.errors.full_messages.to_sentence
  end

  def revoke
    authorize @invitation, :revoke?
    invitation = Organizations::Invitations::Revoke.new(
      actor: Current.user,
      invitation_id: @invitation.id
    ).call
    notice = invitation.revoked? ? "Invitation revoked." : "Invitation expired."

    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      notice: notice
  rescue ActiveRecord::RecordInvalid => error
    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      alert: error.record.errors.full_messages.to_sentence
  end

  private
    def set_invitation
      @invitation = Current.organization.organization_invitations.find(params[:id])
    end

    def invitation_params
      params.expect(organization_invitation: %i[email_address organization_role])
    end

    def deliver_invitation(result)
      return unless result.deliver?

      OrganizationInvitationMailer.deliver_invitation!(
        invitation: result.invitation,
        raw_token: result.raw_token
      )
    end

    def redirect_to_members_with_rate_limit
      redirect_to organization_members_path(organization_slug: Current.organization.slug),
        status: :see_other,
        alert: "Please wait before sending another invitation."
    end
end
