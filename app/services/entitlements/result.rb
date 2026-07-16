module Entitlements
  class Result
    UNLIMITED = :unlimited

    REASON_CODES = %i[
      active_free_plan_missing
      catalog_snapshot_invalid
      feature_disabled
      feature_enabled
      feature_kind_mismatch
      feature_not_entitled
      feature_not_found
      invalid_limit_configuration
      no_current_subscription
      no_effective_plan
      product_enabled
      product_not_found
      product_not_in_plan
      subscription_active
      subscription_cancelled_ended
      subscription_cancelled_missing_end
      subscription_cancelled_with_access
      subscription_expired
      subscription_not_current
      subscription_on_trial
      subscription_past_due_grace
      subscription_past_due_grace_expired
      subscription_past_due_future_start
      subscription_past_due_missing_start
      subscription_paused
      subscription_plan_is_free
      subscription_plan_missing
      subscription_unknown_status
      subscription_unpaid
    ].freeze

    attr_reader :reason_code,
      :plan_key,
      :plan_source,
      :product_key,
      :feature_key,
      :feature_kind,
      :limit_value,
      :details

    def initialize(
      allowed:,
      reason_code:,
      plan_key: nil,
      plan_source: nil,
      product_key: nil,
      feature_key: nil,
      feature_kind: nil,
      limit_value: nil,
      unlimited: false,
      details: {}
    )
      normalized_reason_code = reason_code.to_sym
      unless REASON_CODES.include?(normalized_reason_code)
        raise ArgumentError, "unknown entitlement reason code"
      end
      unless [ true, false ].include?(allowed) && [ true, false ].include?(unlimited)
        raise ArgumentError, "allowed and unlimited must be booleans"
      end

      @allowed = allowed
      @reason_code = normalized_reason_code
      @plan_key = immutable_copy(plan_key)
      @plan_source = plan_source&.to_sym
      @product_key = immutable_copy(product_key)
      @feature_key = immutable_copy(feature_key)
      @feature_kind = feature_kind&.to_sym
      @limit_value = limit_value
      @unlimited = unlimited
      @details = immutable_copy(details.to_h)
      freeze
    end

    def allowed?
      @allowed
    end

    def denied?
      !allowed?
    end

    def unlimited?
      @unlimited
    end

    def capacity
      return unless allowed? && feature_kind == :limit

      unlimited? ? UNLIMITED : limit_value
    end

    private
      def immutable_copy(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), copy|
            copy[immutable_copy(key)] = immutable_copy(nested_value)
          end.freeze
        when Array
          value.map { |nested_value| immutable_copy(nested_value) }.freeze
        else
          value.dup.freeze
        end
      rescue TypeError
        value.freeze
      end
  end
end
