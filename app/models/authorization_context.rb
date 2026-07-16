class AuthorizationContext
  attr_reader :user, :organization, :membership

  def self.current
    new(
      user: Current.user,
      organization: Current.organization,
      membership: Current.membership
    )
  end

  def initialize(user:, organization:, membership:)
    @user = user
    @organization = organization
    @membership = membership
    freeze
  end

  def authenticated?(now: Time.current)
    session = Current.session
    current_user = Current.user

    return false unless user&.persisted? && user.authentication_allowed?
    return false unless session&.persisted? && current_user&.id == user.id
    return false unless session.user_id == user.id

    Session.joins(:user)
      .where(id: session.id, user_id: user.id)
      .where("sessions.expires_at > ?", now)
      .where(users: { disabled_at: nil })
      .where.not(users: { email_verified_at: nil })
      .exists?
  end
end
