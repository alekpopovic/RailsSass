module Billing
  class LifecycleDelivery < ApplicationRecord
    KINDS = %w[
      subscription_activated
      payment_problem
      cancellation_scheduled
      subscription_expired
      plan_change_completed
    ].freeze
    MAX_ATTEMPTS = 8
    FAILURE_CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/

    belongs_to :organization, inverse_of: :billing_lifecycle_deliveries
    belongs_to :audit_event
    belongs_to :billing_subscription,
      class_name: "Billing::Subscription"
    belongs_to :source_webhook_event,
      class_name: "Billing::WebhookEvent"
    belongs_to :recipient_user,
      class_name: "User"

    enum :kind, KINDS.index_with(&:itself), prefix: true, validate: true
    enum :status, {
      pending: "pending",
      processing: "processing",
      delivered: "delivered",
      failed: "failed",
      discarded: "discarded"
    }, prefix: true, validate: true

    scope :due, ->(now) { where(available_at: ..now) }
    scope :recoverable, -> do
      where(status: %w[pending failed])
        .where("attempts_count < ?", MAX_ATTEMPTS)
    end

    attr_readonly :organization_id,
      :audit_event_id,
      :billing_subscription_id,
      :source_webhook_event_id,
      :recipient_user_id,
      :kind

    validates :attempts_count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :available_at, presence: true
    validates :failure_code,
      length: { maximum: 64 },
      format: { with: FAILURE_CODE_PATTERN },
      allow_nil: true
    validate :tenant_relationships_match
    validate :lifecycle_is_consistent
    validate :timestamps_are_monotonic

    private
      def tenant_relationships_match
        relationships = [ audit_event, billing_subscription, source_webhook_event ]
        return if organization_id.blank? || relationships.compact.empty?

        relationships.compact.each do |record|
          if record.organization_id != organization_id
            errors.add(record.model_name.singular.to_sym, "must belong to the organization")
          end
        end
      end

      def lifecycle_is_consistent
        if status_pending?
          errors.add(:claimed_at, "must be blank") if claimed_at.present?
          errors.add(:delivered_at, "must be blank") if delivered_at.present?
          errors.add(:failure_code, "must be blank") if failure_code.present?
        elsif status_processing?
          require_claim_without_terminal_state
          errors.add(:failure_code, "must be blank") if failure_code.present?
        elsif status_delivered?
          errors.add(:claimed_at, "must be present") if claimed_at.blank?
          errors.add(:delivered_at, "must be present") if delivered_at.blank?
          errors.add(:failure_code, "must be blank") if failure_code.present?
        elsif status_failed? || status_discarded?
          require_claim_without_terminal_state
          errors.add(:failure_code, "must be present") if failure_code.blank?
        end
      end

      def require_claim_without_terminal_state
        errors.add(:claimed_at, "must be present") if claimed_at.blank?
        errors.add(:delivered_at, "must be blank") if delivered_at.present?
      end

      def timestamps_are_monotonic
        if claimed_at.present? && available_at.present? && claimed_at < available_at
          errors.add(:claimed_at, "must not be before availability")
        end
        if delivered_at.present? && claimed_at.present? && delivered_at < claimed_at
          errors.add(:delivered_at, "must not be before claim")
        end
      end
  end
end
