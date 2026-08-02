require "digest"

class User < ApplicationRecord
  EMAIL_MAX_LENGTH = 254
  NAME_MAX_LENGTH = 100
  MINIMUM_PASSWORD_LENGTH = 12
  AUTHENTICATION_TOKEN_MAX_BYTES = 2_048
  EMAIL_VERIFICATION_TOKEN_LIFETIME = 24.hours

  has_secure_password reset_token: { expires_in: 15.minutes }

  has_many :sessions, dependent: :destroy
  has_many :organization_memberships, dependent: :restrict_with_exception, inverse_of: :user
  has_many :organization_access_locators,
    dependent: :restrict_with_exception,
    inverse_of: :user
  has_many :sent_organization_invitations,
    class_name: "OrganizationInvitation",
    foreign_key: :inviter_id,
    dependent: :restrict_with_exception,
    inverse_of: :inviter
  has_many :audit_events_as_actor,
    class_name: "AuditEvent",
    foreign_key: :actor_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :actor_user
  has_many :platform_audit_events_as_actor,
    class_name: "Platform::AuditEvent",
    foreign_key: :actor_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :actor_user
  has_many :organizations, through: :organization_memberships

  enum :system_role, { user: "user", platform_admin: "platform_admin" },
    default: :user,
    validate: true

  normalizes :name, with: ->(name) { name.strip }
  normalizes :email_address, with: ->(email) { normalize_email(email) }

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :email_address,
    presence: true,
    length: { maximum: EMAIL_MAX_LENGTH },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, if: -> { password.present? }

  generates_token_for :email_verification, expires_in: EMAIL_VERIFICATION_TOKEN_LIFETIME do
    [ Digest::SHA256.hexdigest(email_address), email_verified_at&.iso8601(6) ]
  end

  before_validation :clear_email_verification_after_address_change,
    if: :will_save_change_to_email_address?

  class << self
    def normalize_email(email_address)
      email_address.to_s.strip.downcase
    end

    def find_by_password_reset_token(token)
      bounded_token = bounded_authentication_token(token)
      find_by_token_for(:password_reset, bounded_token) if bounded_token
    end

    def find_by_password_reset_token!(token)
      bounded_token = bounded_authentication_token(token)
      raise ActiveSupport::MessageVerifier::InvalidSignature unless bounded_token

      find_by_token_for!(:password_reset, bounded_token)
    end

    def find_by_email_verification_token(token)
      bounded_token = bounded_authentication_token(token)
      find_by_token_for(:email_verification, bounded_token) if bounded_token
    end

    def bounded_authentication_token(token)
      normalized = token.to_s
      return if normalized.blank? || normalized.bytesize > AUTHENTICATION_TOKEN_MAX_BYTES

      normalized
    end
  end

  def email_verification_token
    generate_token_for(:email_verification)
  end

  def email_verified?
    email_verified_at.present?
  end

  def disabled?
    disabled_at.present?
  end

  def authentication_allowed?
    email_verified? && !disabled?
  end

  def password_reset_allowed?
    !disabled?
  end

  def email_verification_allowed?
    !email_verified? && !disabled?
  end

  def verify_email!
    update!(email_verified_at: Time.current) unless email_verified?
  end

  private
    def clear_email_verification_after_address_change
      self.email_verified_at = nil if persisted?
    end
end
