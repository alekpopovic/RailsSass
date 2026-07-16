module Billing
  class ProviderLocator < ApplicationRecord
    TOKEN_DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

    belongs_to :organization, inverse_of: :billing_provider_locators
    belongs_to :checkout_attempt,
      class_name: "Billing::CheckoutAttempt",
      foreign_key: :billing_checkout_attempt_id,
      inverse_of: :provider_locator
    belongs_to :billing_subscription,
      class_name: "Billing::Subscription",
      optional: true,
      inverse_of: :provider_locator

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true
    enum :status, {
      unresolved: "unresolved",
      consumed: "consumed",
      definitive_creation_failure: "definitive_creation_failure"
    }, prefix: true, validate: true

    normalizes :provider_subscription_id,
      with: ->(identifier) { identifier.to_s.strip.presence }

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
    validates :provider_subscription_id,
      length: { maximum: 128 },
      format: { with: Billing::Subscription::PROVIDER_ID_PATTERN },
      allow_nil: true
    validate :identity_matches_checkout_attempt
    validate :identity_matches_billing_subscription
    validate :lifecycle_is_consistent
    validate :subscription_identity_is_one_way, on: :update

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
          errors.add(:provider_subscription_id, "must be blank") if provider_subscription_id.present?
          errors.add(:billing_subscription, "must be blank") if billing_subscription_id.present?
        elsif status_consumed?
          errors.add(:resolved_at, "must be present") if resolved_at.blank?
          errors.add(:provider_subscription_id, "must be present") if provider_subscription_id.blank?
        else
          errors.add(:resolved_at, "must be present") if resolved_at.blank?
          errors.add(:provider_subscription_id, "must be blank") if provider_subscription_id.present?
          errors.add(:billing_subscription, "must be blank") if billing_subscription_id.present?
        end
      end

      def identity_matches_billing_subscription
        return unless billing_subscription

        expected = [
          organization_id,
          provider,
          environment,
          provider_subscription_id,
          billing_checkout_attempt_id
        ]
        actual = [
          billing_subscription.organization_id,
          billing_subscription.provider,
          billing_subscription.environment,
          billing_subscription.provider_subscription_id,
          billing_subscription.origin_checkout_attempt_id
        ]
        errors.add(:billing_subscription, "must match the provider subscription identity") unless actual == expected
      end

      def subscription_identity_is_one_way
        if provider_subscription_id_in_database.present? &&
            will_save_change_to_provider_subscription_id?
          errors.add(:provider_subscription_id, "cannot change after resolution")
        end
        if billing_subscription_id_in_database.present? &&
            will_save_change_to_billing_subscription_id?
          errors.add(:billing_subscription, "cannot change after binding")
        end
      end
  end
end
