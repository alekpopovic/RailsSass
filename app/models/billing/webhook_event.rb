module Billing
  class WebhookEvent < ApplicationRecord
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
    PROVIDER_ID_PATTERN = /\A\S+\z/
    CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/
    SNAPSHOT_KEYS = %w[
      ends_at event_name provider_customer_id provider_product_id
      provider_resource_id provider_store_id provider_subscription_id
      provider_updated_at provider_variant_id reason_code renews_at resource_type
      status test_mode trial_ends_at
    ].freeze

    belongs_to :organization, optional: true, inverse_of: :billing_webhook_events

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true
    enum :status, {
      received: "received",
      processing: "processing",
      processed: "processed",
      ignored: "ignored",
      quarantined: "quarantined",
      failed: "failed"
    }, prefix: true, validate: true

    normalizes :provider_event_id, :event_name, :provider_resource_id, :error_code,
      with: ->(value) { value.to_s.strip.presence }

    attr_readonly :provider,
      :environment,
      :fingerprint,
      :provider_event_id,
      :received_at,
      :verified_at

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :fingerprint,
      presence: true,
      length: { is: 64 },
      format: { with: DIGEST_PATTERN },
      uniqueness: true
    validates :event_name, length: { maximum: 100 }, allow_nil: true
    validates :provider_event_id,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN },
      allow_nil: true
    validates :provider_resource_id,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN },
      allow_nil: true
    validates :error_code,
      length: { maximum: 64 },
      format: { with: CODE_PATTERN },
      allow_nil: true
    validates :attempt_count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :received_at, :verified_at, presence: true
    validates :test_mode, inclusion: { in: [ true, false ] }, allow_nil: true
    validate :test_mode_matches_environment
    validate :lifecycle_is_consistent
    validate :snapshot_is_sanitized

    private
      def test_mode_matches_environment
        return if environment.blank? || test_mode.nil?
        return if (environment_test? && test_mode) || (environment_live? && !test_mode)

        errors.add(:test_mode, "must match the provider environment")
      end

      def lifecycle_is_consistent
        if status_received? || status_processing?
          errors.add(:processed_at, "must be blank") if processed_at.present?
          errors.add(:error_code, "must be blank") if error_code.present?
        elsif status_processed? || status_ignored?
          errors.add(:processed_at, "must be present") if processed_at.blank?
          errors.add(:error_code, "must be blank") if error_code.present?
        elsif status_quarantined? || status_failed?
          errors.add(:processed_at, "must be present") if processed_at.blank?
          errors.add(:error_code, "must be present") if error_code.blank?
        end
      end

      def snapshot_is_sanitized
        Billing::SanitizedPayload.validate(self, :snapshot, allowed_keys: SNAPSHOT_KEYS)
      end
  end
end
