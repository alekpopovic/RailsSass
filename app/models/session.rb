require "digest"
require "securerandom"

class Session < ApplicationRecord
  TOKEN_BYTES = 32
  TOKEN_DIGEST_LENGTH = 64
  USER_AGENT_MAX_LENGTH = 512
  LIFETIME = 30.days
  MAX_TOKEN_GENERATION_ATTEMPTS = 3

  belongs_to :user

  validates :token_digest,
    presence: true,
    length: { is: TOKEN_DIGEST_LENGTH },
    format: { with: /\A[0-9a-f]{64}\z/ },
    uniqueness: true
  validates :expires_at, comparison: { greater_than: :created_at }, if: -> { created_at.present? }
  validates :user_agent, length: { maximum: USER_AGENT_MAX_LENGTH }, allow_nil: true

  scope :active, -> { where("expires_at > ?", Time.current) }

  class << self
    def issue_for!(user, ip_address:, user_agent:)
      attempts = 0

      begin
        raw_token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        session = user.sessions.create!(
          token_digest: digest(raw_token),
          ip_address: ip_address,
          user_agent: user_agent.to_s.first(USER_AGENT_MAX_LENGTH).presence,
          expires_at: LIFETIME.from_now
        )

        [ session, raw_token ]
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < MAX_TOKEN_GENERATION_ATTEMPTS

        raise
      end
    end

    def find_by_token(raw_token)
      return if raw_token.blank?

      find_by(token_digest: digest(raw_token))
    end

    private
      def digest(raw_token)
        Digest::SHA256.hexdigest(raw_token)
      end
  end

  def expired?
    expires_at <= Time.current
  end
end
