module Entitlements
  class Usage
    UNLIMITED = Result::UNLIMITED
    SEAT_FEATURE_KEY = "seat_limit"

    class DefinitionMissing < StandardError; end

    Item = Data.define(:resource_type, :identifier, :label) do
      def initialize(resource_type:, identifier:, label:)
        super(
          resource_type: resource_type.to_s.dup.freeze,
          identifier: identifier.to_s.dup.freeze,
          label: label.to_s.dup.freeze
        )
      end
    end

    Key = Data.define(:product_key, :feature_key) do
      def initialize(product_key:, feature_key:)
        super(
          product_key: product_key.to_s.dup.freeze,
          feature_key: feature_key.to_s.dup.freeze
        )
      end
    end

    attr_reader :product_key,
      :feature_key,
      :used,
      :limit,
      :unit,
      :attempted_delta,
      :remediation_items

    class << self
      def registered_keys(organization: Current.organization)
        validate_context!(organization)

        keys = [ Key.new(product_key: "analytics", feature_key: "report_limit") ]
        seat_product_keys.each do |product_key|
          keys << Key.new(product_key: product_key, feature_key: SEAT_FEATURE_KEY)
        end
        keys.uniq.sort_by { |key| [ key.product_key, key.feature_key ] }.freeze
      end

      def registered?(organization:, product_key:, feature_key:)
        validate_context!(organization)
        key = Key.new(product_key: product_key, feature_key: feature_key)
        return true if report_limit_key?(key)

        seat_limit_key?(key) && seat_product_keys.include?(key.product_key)
      end

      def measure(organization:, product_key:, feature_key:, limit:, delta: 0)
        validate_context!(organization)
        validate_limit!(limit)
        validate_delta!(delta)

        key = Key.new(product_key: product_key, feature_key: feature_key)
        unless registered?(
          organization: organization,
          product_key: key.product_key,
          feature_key: key.feature_key
        )
          raise DefinitionMissing, "usage definition is not registered"
        end

        used, unit, item_resolver = measurement(organization, key)
        required_reduction = required_reduction(used:, limit:, delta:)
        items = required_reduction.positive? ? item_resolver.call(required_reduction) : []

        new(
          product_key: key.product_key,
          feature_key: key.feature_key,
          used: used,
          limit: limit,
          unit: unit,
          attempted_delta: delta,
          remediation_items: items
        )
      end

      private
        def validate_context!(organization)
          valid = organization&.persisted? && Current.organization&.id == organization.id
          raise ActiveRecord::RecordNotFound unless valid
        end

        def validate_limit!(limit)
          return if limit == UNLIMITED
          return if limit.is_a?(Integer) && limit >= 0

          raise ArgumentError, "limit must be a non-negative integer or unlimited"
        end

        def validate_delta!(delta)
          return if delta.is_a?(Integer) && delta >= 0

          raise ArgumentError, "delta must be a non-negative integer"
        end

        def seat_product_keys
          ProductFeature
            .joins(:product)
            .where(key: SEAT_FEATURE_KEY, kind: "limit")
            .distinct
            .order("products.key")
            .pluck("products.key")
        end

        def report_limit_key?(key)
          key.product_key == "analytics" && key.feature_key == "report_limit"
        end

        def seat_limit_key?(key)
          key.feature_key == SEAT_FEATURE_KEY
        end

        def measurement(organization, key)
          if report_limit_key?(key)
            report_measurement(organization)
          elsif seat_limit_key?(key)
            seat_measurement(organization, key.product_key)
          else
            raise DefinitionMissing, "usage definition is not registered"
          end
        end

        def report_measurement(organization)
          scope = organization.analytics_reports
          items = lambda do |count|
            scope.order(created_at: :desc, id: :desc).limit(count).map do |report|
              Item.new(
                resource_type: "analytics_report",
                identifier: report.public_id,
                label: report.name
              )
            end
          end
          [ scope.count, "reports", items ]
        end

        def seat_measurement(organization, product_key)
          product_id = Product.where(key: product_key).pick(:id)
          raise DefinitionMissing, "usage product is not registered" unless product_id

          scope = organization.product_memberships.where(
            product_id: product_id,
            status: "active"
          )
          items = lambda do |count|
            scope
              .includes(organization_membership: :user)
              .order(created_at: :desc, id: :desc)
              .limit(count)
              .map do |product_membership|
                user = product_membership.organization_membership.user
                Item.new(
                  resource_type: "product_membership",
                  identifier: product_membership.id,
                  label: user.name
                )
              end
          end
          [ scope.count, "seats", items ]
        end

        def required_reduction(used:, limit:, delta:)
          return 0 if limit == UNLIMITED

          [ used + delta - limit, 0 ].max
        end
    end

    def initialize(
      product_key:,
      feature_key:,
      used:,
      limit:,
      unit:,
      attempted_delta:,
      remediation_items:
    )
      unless used.is_a?(Integer) && used >= 0 &&
          attempted_delta.is_a?(Integer) && attempted_delta >= 0 &&
          remediation_items.all?(Item)
        raise ArgumentError, "usage values are invalid"
      end

      @product_key = product_key.to_s.dup.freeze
      @feature_key = feature_key.to_s.dup.freeze
      @used = used
      @limit = limit
      @unit = unit.to_s.dup.freeze
      @attempted_delta = attempted_delta
      @remediation_items = remediation_items.dup.freeze
      freeze
    end

    def finite?
      !unlimited?
    end

    def unlimited?
      limit == UNLIMITED
    end

    def remaining
      return if unlimited?

      [ limit - used, 0 ].max
    end

    def overage
      return 0 if unlimited?

      [ used - limit, 0 ].max
    end

    def over_limit?
      overage.positive?
    end

    def exhausted?
      finite? && used >= limit
    end

    def allows?(delta = attempted_delta)
      return false unless delta.is_a?(Integer) && delta >= 0

      unlimited? || used + delta <= limit
    end

    def required_reduction
      return 0 if unlimited?

      [ used + attempted_delta - limit, 0 ].max
    end
  end
end
