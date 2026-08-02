require "digest"

class OrganizationInvitation < ApplicationRecord
  EMAIL_MAX_LENGTH = 254
  RAW_TOKEN_MAX_BYTES = 2_048
  TOKEN_DIGEST_LENGTH = 64
  TOKEN_DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

  belongs_to :organization, inverse_of: :organization_invitations
  belongs_to :inviter,
    class_name: "User",
    inverse_of: :sent_organization_invitations

  enum :organization_role, {
    owner: "owner",
    admin: "admin",
    billing: "billing",
    member: "member"
  }, validate: true
  enum :status, {
    pending: "pending",
    accepted: "accepted",
    revoked: "revoked",
    expired: "expired"
  }, default: :pending, validate: true

  normalizes :email_address, with: ->(email_address) { User.normalize_email(email_address) }

  scope :active_at, ->(now = Time.current) { pending.where("expires_at > ?", now) }

  attr_readonly :organization_id, :inviter_id, :email_address, :organization_role

  validates :email_address,
    presence: true,
    length: { maximum: EMAIL_MAX_LENGTH },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: {
      scope: :organization_id,
      case_sensitive: false,
      conditions: -> { pending }
    },
    if: :pending?
  validates :token_digest,
    presence: true,
    length: { is: TOKEN_DIGEST_LENGTH },
    format: { with: TOKEN_DIGEST_PATTERN },
    uniqueness: true
  validates :expires_at, presence: true
  validate :lifecycle_timestamps_match_status
  validate :accepted_at_is_within_lifetime
  validate :revoked_at_is_not_before_creation

  class << self
    def digest_token(raw_token)
      normalized = raw_token.to_s
      return if normalized.blank? || normalized.bytesize > RAW_TOKEN_MAX_BYTES

      Digest::SHA256.hexdigest(normalized)
    end
  end

  def expired_for?(now: Time.current)
    expires_at.blank? || expires_at <= now
  end

  private
    def lifecycle_timestamps_match_status
      case status
      when "pending", "expired"
        errors.add(:accepted_at, "must be blank") if accepted_at.present?
        errors.add(:revoked_at, "must be blank") if revoked_at.present?
      when "accepted"
        errors.add(:accepted_at, "must be present") if accepted_at.blank?
        errors.add(:revoked_at, "must be blank") if revoked_at.present?
      when "revoked"
        errors.add(:accepted_at, "must be blank") if accepted_at.present?
        errors.add(:revoked_at, "must be present") if revoked_at.blank?
      end
    end

    def accepted_at_is_within_lifetime
      return if accepted_at.blank? || created_at.blank? || expires_at.blank?
      return if accepted_at >= created_at && accepted_at < expires_at

      errors.add(:accepted_at, "must be within the invitation lifetime")
    end

    def revoked_at_is_not_before_creation
      return if revoked_at.blank? || created_at.blank? || revoked_at >= created_at

      errors.add(:revoked_at, "cannot be before creation")
    end
end
