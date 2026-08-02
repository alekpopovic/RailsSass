class Accounts::Authenticate
  Result = Data.define(:status, :user, :session, :raw_token) do
    def authenticated?
      status == :authenticated
    end
  end

  def initialize(email_address:, password:, ip_address:, user_agent:)
    @email_address = User.normalize_email(email_address)
    @password = password
    @ip_address = ip_address
    @user_agent = user_agent
  end

  def call
    candidate = User.authenticate_by(
      email_address: @email_address,
      password: @password
    )
    return invalid_credentials unless candidate&.authentication_allowed?

    authenticated_password_digest = candidate.password_digest

    # Password reset takes the same row lock before changing the digest and
    # deleting sessions. Whichever command locks first therefore wins safely:
    # reset-first invalidates this snapshot, while login-first creates a session
    # that the following reset deletes.
    User.transaction do
      candidate.lock!
      next invalid_credentials unless candidate.email_address == @email_address
      next invalid_credentials unless candidate.authentication_allowed?
      next invalid_credentials unless unchanged_password_digest?(
        candidate.password_digest,
        authenticated_password_digest
      )

      session, raw_token = Session.issue_for!(
        candidate,
        ip_address: @ip_address,
        user_agent: @user_agent
      )
      Result.new(
        status: :authenticated,
        user: candidate,
        session: session,
        raw_token: raw_token
      )
    end
  rescue ActiveRecord::RecordNotFound
    invalid_credentials
  end

  private
    def unchanged_password_digest?(current_digest, authenticated_digest)
      ActiveSupport::SecurityUtils.secure_compare(
        current_digest.to_s,
        authenticated_digest.to_s
      )
    end

    def invalid_credentials
      Result.new(status: :invalid_credentials, user: nil, session: nil, raw_token: nil)
    end
end
