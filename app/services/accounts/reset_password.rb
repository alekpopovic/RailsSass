class Accounts::ResetPassword
  Result = Data.define(:status, :user) do
    def updated?
      status == :updated
    end

    def invalid_token?
      status == :invalid_token
    end
  end

  def initialize(raw_token:, attributes:)
    @raw_token = raw_token.to_s
    @attributes = attributes
  end

  def call
    candidate = User.find_by_password_reset_token(@raw_token)
    return invalid_token unless candidate&.password_reset_allowed?

    User.transaction do
      candidate.lock!
      current_candidate = User.find_by_password_reset_token(@raw_token)
      next invalid_token unless current_candidate&.id == candidate.id
      next invalid_token unless candidate.password_reset_allowed?

      if candidate.update(@attributes)
        candidate.sessions.delete_all
        Result.new(status: :updated, user: candidate)
      else
        Result.new(status: :invalid_attributes, user: candidate)
      end
    end
  rescue ActiveRecord::RecordNotFound
    invalid_token
  end

  private
    def invalid_token
      Result.new(status: :invalid_token, user: nil)
    end
end
