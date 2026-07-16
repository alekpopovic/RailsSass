module Entitlements
  class LimitEnforcer
    CAPACITY_NOT_PROVIDED = Object.new.freeze

    class << self
      def current_usages(organization:, now: Time.current)
        validate_context!(organization)
        resolver = Resolver.new(organization: organization, now: now)

        Usage.registered_keys(organization: organization).filter_map do |key|
          new(
            organization: organization,
            product_key: key.product_key,
            feature_key: key.feature_key,
            resolver: resolver
          ).status
        end.freeze
      end

      private
        def validate_context!(organization)
          valid = organization&.persisted? && Current.organization&.id == organization.id
          raise ActiveRecord::RecordNotFound unless valid
        end
    end

    def initialize(
      organization:,
      product_key:,
      feature_key:,
      capacity: CAPACITY_NOT_PROVIDED,
      resolver: nil
    )
      self.class.send(:validate_context!, organization)
      @organization = organization
      @product_key = product_key.to_s
      @feature_key = feature_key.to_s
      @provided_capacity = capacity
      @resolver = resolver
    end

    def status(delta: 0)
      return unless registered?

      Usage.measure(
        organization: organization,
        product_key: product_key,
        feature_key: feature_key,
        limit: capacity,
        delta: delta
      )
    end

    def enforce!(delta:)
      usage = status(delta: delta)
      return unless usage
      raise OverLimit.new(usage: usage) if usage.over_limit?
      raise LimitExceeded.new(usage: usage) unless usage.allows?

      usage
    end

    private
      attr_reader :organization, :product_key, :feature_key, :provided_capacity, :resolver

      def registered?
        Usage.registered?(
          organization: organization,
          product_key: product_key,
          feature_key: feature_key
        )
      end

      def capacity
        return 0 unless active_limit_feature?
        return validate_capacity!(provided_capacity) unless
          provided_capacity.equal?(CAPACITY_NOT_PROVIDED)

        decision = entitlement_resolver.explain(
          product_key: product_key,
          feature_key: feature_key
        )
        return 0 unless decision.allowed? && decision.feature_kind == :limit

        validate_capacity!(decision.capacity)
      end

      def entitlement_resolver
        resolver || Resolver.new(organization: organization)
      end

      def active_limit_feature?
        ProductFeature
          .joins(:product)
          .where(
            products: { key: product_key, active: true },
            product_features: {
              key: feature_key,
              kind: "limit",
              active: true
            }
          )
          .exists?
      end

      def validate_capacity!(value)
        return value if value == Usage::UNLIMITED
        return value if value.is_a?(Integer) && value >= 0

        raise ArgumentError, "capacity must be a non-negative integer or unlimited"
      end
  end
end
