require "set"

module Products
  class PlanCompatibility
    UNLIMITED = Entitlements::Usage::UNLIMITED
    CLASSIFICATIONS = %i[upgrade downgrade same_plan change].freeze

    CapabilityKey = Data.define(:product_key, :feature_key) do
      def initialize(product_key:, feature_key:)
        super(
          product_key: product_key.to_s.dup.freeze,
          feature_key: feature_key.to_s.dup.freeze
        )
      end
    end

    Issue = Data.define(
      :product_key,
      :feature_key,
      :reason_code,
      :usage,
      :capacity,
      :unit,
      :usage_details
    ) do
      MESSAGES = {
        limit_exceeded: "Current usage exceeds the selected plan limit.",
        usage_resolver_missing: "This plan limit cannot be verified safely."
      }.freeze

      def initialize(
        product_key:,
        feature_key:,
        reason_code:,
        usage:,
        capacity:,
        unit: nil,
        usage_details: nil
      )
        normalized_reason = reason_code.to_sym
        raise ArgumentError, "unknown compatibility issue" unless MESSAGES.key?(normalized_reason)

        super(
          product_key: product_key.to_s.dup.freeze,
          feature_key: feature_key.to_s.dup.freeze,
          reason_code: normalized_reason,
          usage: usage,
          capacity: capacity,
          unit: unit&.to_s&.dup&.freeze,
          usage_details: usage_details
        )
      end

      def message
        MESSAGES.fetch(reason_code)
      end

      def over_limit?
        reason_code == :limit_exceeded
      end
    end

    class CapabilitySnapshot
      attr_reader :products, :flags, :enabled_limits, :limits

      def initialize(products:, flags:, enabled_limits:, limits:)
        @products = immutable_keys(products)
        @flags = immutable_capability_keys(flags)
        @enabled_limits = immutable_capability_keys(enabled_limits)
        @limits = limits
          .sort_by { |key, _capacity| [ key.product_key, key.feature_key ] }
          .to_h
          .freeze
        freeze
      end

      def dominates?(other)
        products.to_set.superset?(other.products.to_set) &&
          flags.to_set.superset?(other.flags.to_set) &&
          enabled_limits.to_set.superset?(other.enabled_limits.to_set) &&
          capacities_dominate?(other)
      end

      def ==(other)
        other.is_a?(self.class) &&
          products == other.products &&
          flags == other.flags &&
          enabled_limits == other.enabled_limits &&
          limits == other.limits
      end

      private
        def immutable_keys(values)
          values.map { |value| value.to_s.dup.freeze }.uniq.sort.freeze
        end

        def immutable_capability_keys(values)
          values.uniq.sort_by { |key| [ key.product_key, key.feature_key ] }.freeze
        end

        def capacities_dominate?(other)
          (limits.keys | other.limits.keys).all? do |key|
            capacity_at_least?(limits.fetch(key, 0), other.limits.fetch(key, 0))
          end
        end

        def capacity_at_least?(capacity, other_capacity)
          return true if capacity == UNLIMITED
          return false if other_capacity == UNLIMITED

          capacity >= other_capacity
        end
    end

    class Result
      attr_reader :classification, :issues, :from_capabilities, :to_capabilities

      def initialize(classification:, issues:, from_capabilities:, to_capabilities:)
        normalized_classification = classification.to_sym
        unless CLASSIFICATIONS.include?(normalized_classification)
          raise ArgumentError, "unknown plan-change classification"
        end

        @classification = normalized_classification
        @issues = issues.dup.freeze
        @from_capabilities = from_capabilities
        @to_capabilities = to_capabilities
        freeze
      end

      def compatible?
        issues.empty?
      end

      def incompatible?
        !compatible?
      end

      def over_limit?
        issues.any?(&:over_limit?)
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(organization:, to_plan:, from_plan: nil)
      @organization = organization
      @from_plan = from_plan
      @to_plan = to_plan
    end

    def call
      validate_context!
      to_capabilities = capabilities_for(to_plan)
      from_capabilities = from_plan ? capabilities_for(from_plan) : to_capabilities

      Result.new(
        classification: classification(from_capabilities, to_capabilities),
        issues: compatibility_issues(to_capabilities),
        from_capabilities: from_capabilities,
        to_capabilities: to_capabilities
      )
    end

    private
      attr_reader :organization, :from_plan, :to_plan

      def validate_context!
        valid = organization&.persisted? &&
          Current.organization&.id == organization.id &&
          to_plan&.persisted? &&
          (from_plan.nil? || from_plan.persisted?)
        raise ActiveRecord::RecordNotFound unless valid
      end

      def capabilities_for(plan)
        products = PlanProduct
          .joins(:product)
          .where(plan_id: plan.id, products: { active: true })
          .pluck("products.key")
        flags = []
        enabled_limits = []
        limits = registered_usage_keys.index_with { 0 }

        entitlement_rows(plan).each do |product_key, feature_key, kind, enabled, limit_value, unlimited|
          key = CapabilityKey.new(product_key:, feature_key:)
          case kind
          when "flag"
            flags << key if enabled
          when "limit"
            next unless enabled

            enabled_limits << key
            limits[key] = unlimited ? UNLIMITED : limit_value
          end
        end

        CapabilitySnapshot.new(
          products: products,
          flags: flags,
          enabled_limits: enabled_limits,
          limits: limits
        )
      end

      def entitlement_rows(plan)
        PlanFeatureEntitlement
          .joins(:product, :product_feature)
          .where(
            plan_product_id: PlanProduct.where(plan_id: plan.id).select(:id),
            products: { active: true },
            product_features: { active: true }
          )
          .pluck(
            "products.key",
            "product_features.key",
            :feature_kind,
            :enabled,
            :limit_value,
            :unlimited
          )
      end

      def compatibility_issues(target)
        issues = missing_usage_resolver_issues(target)

        registered_usage_keys.each do |key|
          capacity = target.limits.fetch(key, 0)
          usage = Entitlements::LimitEnforcer.new(
            organization: organization,
            product_key: key.product_key,
            feature_key: key.feature_key,
            capacity: capacity
          ).status
          next unless usage&.over_limit?

          issues << Issue.new(
            product_key: key.product_key,
            feature_key: key.feature_key,
            reason_code: :limit_exceeded,
            usage: usage.used,
            capacity: capacity,
            unit: usage.unit,
            usage_details: usage
          )
        end

        issues.sort_by { |issue| [ issue.product_key, issue.feature_key, issue.reason_code.to_s ] }.freeze
      end

      def missing_usage_resolver_issues(target)
        target.enabled_limits.filter_map do |key|
          next if registered_usage_keys.include?(key)

          Issue.new(
            product_key: key.product_key,
            feature_key: key.feature_key,
            reason_code: :usage_resolver_missing,
            usage: nil,
            capacity: target.limits.fetch(key),
            unit: nil,
            usage_details: nil
          )
        end
      end

      def registered_usage_keys
        @registered_usage_keys ||= Entitlements::Usage
          .registered_keys(organization: organization)
          .map { |key| CapabilityKey.new(product_key: key.product_key, feature_key: key.feature_key) }
          .freeze
      end

      def classification(from_capabilities, to_capabilities)
        return :same_plan if from_plan.nil? || from_plan.id == to_plan.id

        target_dominates = to_capabilities.dominates?(from_capabilities)
        source_dominates = from_capabilities.dominates?(to_capabilities)
        return :upgrade if target_dominates && !source_dominates
        return :downgrade if source_dominates && !target_dominates

        :change
      end
  end
end
