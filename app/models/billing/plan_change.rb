module Billing
  class PlanChange < ApplicationRecord
    CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/
    OPEN_STATUSES = %w[pending submitted creation_unknown].freeze

    belongs_to :organization, inverse_of: :billing_plan_changes
    belongs_to :billing_subscription,
      class_name: "Billing::Subscription",
      inverse_of: :plan_changes
    belongs_to :requested_by_membership,
      class_name: "OrganizationMembership",
      inverse_of: :requested_billing_plan_changes
    belongs_to :from_plan_price,
      class_name: "PlanPrice",
      inverse_of: :billing_plan_changes_from
    belongs_to :to_plan_price,
      class_name: "PlanPrice",
      inverse_of: :billing_plan_changes_to

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true
    enum :status, {
      pending: "pending",
      submitted: "submitted",
      creation_unknown: "creation_unknown",
      applied: "applied",
      failed: "failed",
      superseded: "superseded"
    }, prefix: true, validate: true

    scope :open, -> { where(status: OPEN_STATUSES) }

    normalizes :failure_code, with: ->(value) { value.to_s.strip.presence }

    attr_readonly :organization_id,
      :billing_subscription_id,
      :requested_by_membership_id,
      :from_plan_price_id,
      :to_plan_price_id,
      :provider,
      :environment,
      :test_mode,
      :requested_at

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :test_mode, inclusion: { in: [ true, false ] }
    validates :requested_at, presence: true
    validates :failure_code,
      length: { maximum: 64 },
      format: { with: CODE_PATTERN },
      allow_nil: true
    validate :test_mode_matches_environment
    validate :tenant_relationships_match
    validate :prices_differ
    validate :subscription_is_current, on: :create
    validate :source_price_matches_subscription, on: :create
    validate :lifecycle_is_consistent

    private
      def test_mode_matches_environment
        return if environment.blank? || test_mode.nil?
        return if (environment_test? && test_mode) || (environment_live? && !test_mode)

        errors.add(:test_mode, "must match the provider environment")
      end

      def tenant_relationships_match
        if billing_subscription.present? && !subscription_identity_matches?
          errors.add(:billing_subscription, "must match the tenant and provider identity")
        end
        if requested_by_membership.present? && requested_by_membership.organization_id != organization_id
          errors.add(:requested_by_membership, "must belong to the organization")
        end
      end

      def subscription_identity_matches?
        [
          billing_subscription.organization_id,
          billing_subscription.provider,
          billing_subscription.environment,
          billing_subscription.test_mode
        ] == [ organization_id, provider, environment, test_mode ]
      end

      def prices_differ
        return if from_plan_price_id.blank? || to_plan_price_id.blank?

        errors.add(:to_plan_price, "must differ from the current price") if from_plan_price_id == to_plan_price_id
      end

      def subscription_is_current
        return if billing_subscription.blank? || billing_subscription.current?

        errors.add(:billing_subscription, "must be current when the change is requested")
      end

      def source_price_matches_subscription
        return if billing_subscription.blank? || from_plan_price_id.blank?
        return if billing_subscription.plan_price_id == from_plan_price_id

        errors.add(:from_plan_price, "must match the subscription price")
      end

      def lifecycle_is_consistent
        if status_pending? || status_submitted? || status_creation_unknown?
          errors.add(:completed_at, "must be blank") if completed_at.present?
          errors.add(:failure_code, "must be blank") if failure_code.present?
        elsif status_applied? || status_superseded?
          errors.add(:completed_at, "must be present") if completed_at.blank?
          errors.add(:failure_code, "must be blank") if failure_code.present?
        elsif status_failed?
          errors.add(:completed_at, "must be present") if completed_at.blank?
          errors.add(:failure_code, "must be present") if failure_code.blank?
        end
      end
  end
end
