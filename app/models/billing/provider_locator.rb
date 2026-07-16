module Billing
  class ProviderLocator < ApplicationRecord
    TOKEN_DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

    belongs_to :organization, inverse_of: :billing_provider_locators
    belongs_to :checkout_attempt,
      class_name: "Billing::CheckoutAttempt",
      foreign_key: :billing_checkout_attempt_id,
      inverse_of: :provider_locator

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true
    enum :status, {
      unresolved: "unresolved",
      consumed: "consumed",
      definitive_creation_failure: "definitive_creation_failure"
    }, prefix: true, validate: true

    attr_readonly :organization_id,
      :billing_checkout_attempt_id,
      :provider,
      :environment,
      :token_digest

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :token_digest,
      presence: true,
      length: { is: 64 },
      format: { with: TOKEN_DIGEST_PATTERN }
    validate :identity_matches_checkout_attempt
    validate :lifecycle_is_consistent

    private
      def identity_matches_checkout_attempt
        return unless checkout_attempt

        matches = checkout_attempt.organization_id == organization_id &&
          checkout_attempt.provider == provider &&
          checkout_attempt.environment == environment &&
          checkout_attempt.token_digest == token_digest
        errors.add(:checkout_attempt, "must match the provider locator identity") unless matches
      end

      def lifecycle_is_consistent
        if status_unresolved?
          errors.add(:resolved_at, "must be blank") if resolved_at.present?
        elsif resolved_at.blank?
          errors.add(:resolved_at, "must be present")
        end
      end
  end
end
