class Organizations::Invitations::Lookup < Organizations::Invitations::Base
  def initialize(user:, raw_token:)
    @user = user
    @raw_token = raw_token.to_s
  end

  def call
    organization = Current.organization
    authorized_identity = organization&.active? &&
      @user&.persisted? &&
      Current.user&.id == @user.id &&
      @user.authentication_allowed?
    raise ActiveRecord::RecordNotFound unless authorized_identity && @raw_token.present?

    Current.organization.organization_invitations
      .active_at(Time.current)
      .find_by!(
        email_address: User.normalize_email(@user.email_address),
        token_digest: OrganizationInvitation.digest_token(@raw_token)
      )
  end
end
