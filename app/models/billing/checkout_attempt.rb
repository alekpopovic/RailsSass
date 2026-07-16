module Billing
  class CheckoutAttempt < ApplicationRecord
    TOKEN_DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
    PROVIDER_ID_PATTERN = /\A\S+\z/
    CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/

    belongs_to :organization, inverse_of: :billing_checkout_attempts
    belongs_to :initiated_by_membership,
      class_name: "OrganizationMembership",
      inverse_of: :initiated_billing_checkout_attempts
    belongs_to :plan_price, inverse_of: :billing_checkout_attempts

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true
    enum :status, {
      creating: "creating",
      ready: "ready",
      creation_unknown: "creation_unknown",
      completed: "completed",
      expired: "expired",
      superseded: "superseded",
      failed: "failed"
    }, prefix: true, validate: true

    normalizes :provider_checkout_id, :failure_code,
      with: ->(value) { value.to_s.strip.presence }

    attr_readonly :organization_id,
      :initiated_by_membership_id,
      :plan_price_id,
      :provider,
      :environment,
      :test_mode,
      :token_digest

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :test_mode, inclusion: { in: [ true, false ] }
    validates :token_digest,
      presence: true,
      length: { is: 64 },
      format: { with: TOKEN_DIGEST_PATTERN }
    validates :provider_checkout_id,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN },
      allow_nil: true
    validates :failure_code,
      length: { maximum: 64 },
      format: { with: CODE_PATTERN },
      allow_nil: true
    validates :expires_at, presence: true
    validate :test_mode_matches_environment
    validate :membership_matches_organization
    validate :lifecycle_is_consistent

    private
      def test_mode_matches_environment
        return if environment.blank? || test_mode.nil?
        return if (environment_test? && test_mode) || (environment_live? && !test_mode)

        errors.add(:test_mode, "must match the provider environment")
      end

      def membership_matches_organization
        return if initiated_by_membership.blank? || organization_id.blank?
        return if initiated_by_membership.organization_id == organization_id

        errors.add(:initiated_by_membership, "must belong to the organization")
      end

      def lifecycle_is_consistent
        case status
        when "creating", "creation_unknown"
          require_blank_terminal_fields
        when "ready"
          errors.add(:provider_checkout_id, "must be present") if provider_checkout_id.blank?
          require_blank_terminal_fields
        when "completed"
          errors.add(:provider_checkout_id, "must be present") if provider_checkout_id.blank?
          errors.add(:completed_at, "must be present") if completed_at.blank?
          errors.add(:token_consumed_at, "must be present") if token_consumed_at.blank?
          errors.add(:failure_code, "must be blank") if failure_code.present?
        when "expired", "superseded"
          errors.add(:completed_at, "must be present") if completed_at.blank?
          errors.add(:token_consumed_at, "must be blank") if token_consumed_at.present?
          errors.add(:failure_code, "must be blank") if failure_code.present?
        when "failed"
          errors.add(:completed_at, "must be present") if completed_at.blank?
          errors.add(:token_consumed_at, "must be blank") if token_consumed_at.present?
          errors.add(:failure_code, "must be present") if failure_code.blank?
        end
      end

      def require_blank_terminal_fields
        errors.add(:completed_at, "must be blank") if completed_at.present?
        errors.add(:token_consumed_at, "must be blank") if token_consumed_at.present?
        errors.add(:failure_code, "must be blank") if failure_code.present?
      end
  end
end
