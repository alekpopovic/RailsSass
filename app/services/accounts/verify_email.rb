class Accounts::VerifyEmail
  Result = Data.define(:status, :user) do
    def verified?
      status == :verified
    end

    def invalid_token?
      status == :invalid_token
    end
  end

  def initialize(raw_token:)
    @raw_token = raw_token.to_s
  end

  def call
    candidate = User.find_by_email_verification_token(@raw_token)
    return invalid_token unless candidate&.email_verification_allowed?

    User.transaction do
      candidate.lock!
      current_candidate = User.find_by_email_verification_token(@raw_token)
      next invalid_token unless current_candidate&.id == candidate.id
      next invalid_token unless candidate.email_verification_allowed?

      candidate.verify_email!
      Result.new(status: :verified, user: candidate)
    end
  rescue ActiveRecord::RecordNotFound
    invalid_token
  end

  private
    def invalid_token
      Result.new(status: :invalid_token, user: nil)
    end
end
