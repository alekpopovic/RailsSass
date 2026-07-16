module Billing
  class WebhookEvent < ApplicationRecord
    CURRENT_INGRESS_VERSION = 1
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
    PROVIDER_ID_PATTERN = /\A\S+\z/
    CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/
    RESOURCE_TYPE_PATTERN = /\A[a-z][a-z0-9_-]*\z/
    SNAPSHOT_KEYS = %w[
      card_brand card_last_four checkout_expires_at checkout_organization_public_id
      checkout_plan_price_id checkout_token_digest checkout_user_id ends_at event_name
      mode pause payment_status provider_created_at provider_customer_id
      provider_product_id provider_resource_id provider_store_id provider_subscription_id
      provider_updated_at provider_variant_id reason_code renews_at resource_type
      resumes_at status test_mode trial_ends_at
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

    normalizes :provider_event_id,
      :event_name,
      :external_resource_type,
      :external_resource_id,
      :provider_resource_id,
      :error_code,
      :error_class,
      :error_message,
      with: ->(value) { value.to_s.strip.presence }

    before_validation :synchronize_compatibility_fields

    attr_readonly :provider,
      :environment,
      :fingerprint,
      :body_sha256,
      :provider_event_id,
      :received_at,
      :verified_at,
      :ingress_version

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :fingerprint,
      presence: true,
      length: { is: 64 },
      format: { with: DIGEST_PATTERN },
      uniqueness: true
    validates :body_sha256,
      presence: true,
      length: { is: 64 },
      format: { with: DIGEST_PATTERN },
      uniqueness: { scope: %i[provider environment] }
    validates :event_name, length: { maximum: 100 }, allow_nil: true
    validates :external_resource_type,
      length: { maximum: 64 },
      format: { with: RESOURCE_TYPE_PATTERN },
      allow_nil: true
    validates :provider_event_id,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN },
      allow_nil: true
    validates :provider_resource_id,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN },
      allow_nil: true
    validates :external_resource_id,
      length: { maximum: 128 },
      format: { with: PROVIDER_ID_PATTERN },
      allow_nil: true
    validates :error_code,
      length: { maximum: 64 },
      format: { with: CODE_PATTERN },
      allow_nil: true
    validates :error_class, length: { maximum: 255 }, allow_nil: true
    validates :error_message, length: { maximum: 500 }, allow_nil: true
    validates :attempt_count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :attempts_count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :received_at, :verified_at, presence: true
    validates :ingress_version,
      inclusion: { in: [ CURRENT_INGRESS_VERSION ] },
      allow_nil: true
    validates :test_mode, inclusion: { in: [ true, false ] }, allow_nil: true
    validate :test_mode_matches_environment
    validate :lifecycle_is_consistent
    validate :compatibility_fields_match
    validate :ingress_timestamps_are_consistent
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

      def synchronize_compatibility_fields
        synchronize_pair(:external_resource_id, :provider_resource_id)
        synchronize_pair(:payload, :snapshot)
        synchronize_pair(:attempts_count, :attempt_count)
        self.body_sha256 ||= fingerprint
      end

      def synchronize_pair(primary, legacy)
        primary_changed = will_save_change_to_attribute?(primary)
        legacy_changed = will_save_change_to_attribute?(legacy)

        if primary_changed && !legacy_changed
          self[legacy] = self[primary]
        elsif legacy_changed && !primary_changed
          self[primary] = self[legacy]
        end
      end

      def compatibility_fields_match
        if external_resource_id != provider_resource_id
          errors.add(:external_resource_id, "must match provider resource ID")
        end
        errors.add(:payload, "must match the sanitized snapshot") unless payload == snapshot
        errors.add(:attempts_count, "must match attempt count") unless attempts_count == attempt_count
      end

      def ingress_timestamps_are_consistent
        if processing_started_at && verified_at && processing_started_at < verified_at
          errors.add(:processing_started_at, "must not be before verification")
        end
        if processed_at && processing_started_at && processed_at < processing_started_at
          errors.add(:processed_at, "must not be before processing started")
        end
        if failed_at && verified_at && failed_at < verified_at
          errors.add(:failed_at, "must not be before verification")
        end
        if failed_at && processing_started_at && failed_at < processing_started_at
          errors.add(:failed_at, "must not be before processing started")
        end
        errors.add(:enqueued_at, "must not be before verification") if enqueued_at && verified_at && enqueued_at < verified_at
      end
  end
end
