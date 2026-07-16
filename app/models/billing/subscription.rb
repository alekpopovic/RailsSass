module Billing
  class Subscription < ApplicationRecord
    PROVIDER_ID_PATTERN = /\A\S+\z/
    PAUSE_KEYS = %w[mode resumes_at].freeze
    SNAPSHOT_KEYS = %w[
      card_brand card_last_four ends_at event_name mode pause provider_customer_id
      provider_created_at provider_product_id provider_resource_id provider_store_id
      past_due_started_at provider_subscription_id provider_updated_at provider_variant_id
      reason_code renews_at resource_type resumes_at status test_mode trial_ends_at
    ].freeze

    belongs_to :organization, inverse_of: :billing_subscriptions
    belongs_to :billing_customer,
      class_name: "Billing::Customer",
      inverse_of: :subscriptions
    belongs_to :plan_price, inverse_of: :billing_subscriptions
    belongs_to :origin_plan_price,
      class_name: "PlanPrice",
      inverse_of: :origin_billing_subscriptions
    belongs_to :origin_checkout_attempt,
      class_name: "Billing::CheckoutAttempt",
      optional: true,
      inverse_of: :originated_subscription
    has_one :provider_locator,
      class_name: "Billing::ProviderLocator",
      foreign_key: :billing_subscription_id,
      dependent: :restrict_with_exception,
      inverse_of: :billing_subscription
    has_many :plan_changes,
      class_name: "Billing::PlanChange",
      foreign_key: :billing_subscription_id,
      dependent: :restrict_with_exception,
      inverse_of: :billing_subscription

    before_destroy :prevent_history_deletion

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true
    enum :status, {
      on_trial: "on_trial",
      active: "active",
      paused: "paused",
      past_due: "past_due",
      unpaid: "unpaid",
      cancelled: "cancelled",
      expired: "expired",
      unknown: "unknown"
    }, prefix: true, validate: true
    enum :sync_state, {
      synced: "synced",
      pending: "pending",
      mapping_error: "mapping_error",
      invalid: "invalid"
    }, prefix: true, validate: true

    normalizes :provider_subscription_id, :provider_customer_id,
      with: ->(identifier) { identifier.to_s.strip }
    normalizes :card_brand, :card_last_four,
      with: ->(value) { value.to_s.strip.presence }

    before_validation :set_projection_defaults, on: :create

    attr_readonly :organization_id,
      :billing_customer_id,
      :origin_plan_price_id,
      :origin_checkout_attempt_id,
      :provider,
      :environment,
      :provider_subscription_id,
      :provider_customer_id,
      :test_mode

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :provider_subscription_id,
      presence: true,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN }
    validates :provider_customer_id,
      presence: true,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN }
    validates :current, :test_mode, inclusion: { in: [ true, false ] }
    validates :provider_updated_at, presence: true
    validates :last_seen_provider_updated_at, presence: true
    validates :card_brand, length: { maximum: 32 }, allow_nil: true
    validates :card_last_four,
      format: { with: /\A[0-9]{4}\z/ },
      allow_nil: true
    validate :test_mode_matches_environment
    validate :customer_identity_matches
    validate :origin_identity_matches
    validate :provider_update_order_is_consistent
    validate :archive_state_is_consistent
    validate :archived_state_is_one_way, on: :update
    validate :status_timestamps_are_present
    validate :card_display_is_consistent
    validate :pause_is_a_bounded_object
    validate :raw_payload_is_sanitized

    private
      def test_mode_matches_environment
        return if environment.blank? || test_mode.nil?
        return if (environment_test? && test_mode) || (environment_live? && !test_mode)

        errors.add(:test_mode, "must match the provider environment")
      end

      def customer_identity_matches
        return if billing_customer.blank?

        expected = [ organization_id, provider, environment, test_mode, provider_customer_id ]
        actual = [
          billing_customer.organization_id,
          billing_customer.provider,
          billing_customer.environment,
          billing_customer.test_mode,
          billing_customer.provider_customer_id
        ]
        errors.add(:billing_customer, "must match the tenant and provider identity") unless actual == expected
      end

      def set_projection_defaults
        self.origin_plan_price ||= plan_price
        self.last_seen_provider_updated_at ||= provider_updated_at
      end

      def origin_identity_matches
        return unless origin_checkout_attempt

        expected = [
          organization_id,
          origin_plan_price_id,
          provider,
          environment
        ]
        actual = [
          origin_checkout_attempt.organization_id,
          origin_checkout_attempt.plan_price_id,
          origin_checkout_attempt.provider,
          origin_checkout_attempt.environment
        ]
        errors.add(:origin_checkout_attempt, "must match the subscription origin") unless actual == expected
      end

      def provider_update_order_is_consistent
        return if provider_updated_at.blank? || last_seen_provider_updated_at.blank?
        return unless last_seen_provider_updated_at < provider_updated_at

        errors.add(:last_seen_provider_updated_at, "cannot precede the accepted provider update")
      end

      def archive_state_is_consistent
        return if (current? && archived_at.nil?) || (!current? && archived_at.present?)

        errors.add(:archived_at, "must be blank only for the current subscription")
      end

      def archived_state_is_one_way
        return unless current_in_database == false

        errors.add(:current, "cannot reactivate archived history") if current?
        if will_save_change_to_archived_at?
          errors.add(:archived_at, "cannot change after archival")
        end
      end

      def status_timestamps_are_present
        errors.add(:trial_ends_at, "must be present") if status_on_trial? && trial_ends_at.blank?
        errors.add(:ends_at, "must be present") if status_cancelled? && ends_at.blank?

        if status_past_due?
          errors.add(:past_due_started_at, "must be present") if past_due_started_at.blank?
          if past_due_started_at.present? && provider_updated_at.present? &&
              past_due_started_at > provider_updated_at
            errors.add(:past_due_started_at, "cannot be after the provider update")
          end
        elsif past_due_started_at.present?
          errors.add(:past_due_started_at, "must be blank outside a past-due cycle")
        end
      end

      def card_display_is_consistent
        return if card_brand.blank? && card_last_four.blank?
        return if card_brand.present? && card_last_four.present?

        errors.add(:card_last_four, "must be provided with card brand")
      end

      def pause_is_a_bounded_object
        Billing::SanitizedPayload.validate(self, :pause, allowed_keys: PAUSE_KEYS)
      end

      def raw_payload_is_sanitized
        Billing::SanitizedPayload.validate(self, :raw_payload, allowed_keys: SNAPSHOT_KEYS)
      end

      def prevent_history_deletion
        errors.add(:base, "billing subscription history must be archived, not deleted")
        throw :abort
      end
  end
end
