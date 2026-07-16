class Access::Decision
  UNLIMITED = Entitlements::Result::UNLIMITED

  OWN_REASON_CODES = %i[
    access_granted
    authentication_required
    organization_context_invalid
    organization_inactive
    organization_membership_inactive
    organization_role_not_product_eligible
    product_membership_missing
    product_membership_suspended
    permission_not_granted
  ].freeze

  ENTITLEMENT_DENIAL_REASON_CODES = %i[
    catalog_snapshot_invalid
    feature_disabled
    feature_kind_mismatch
    feature_not_entitled
    feature_not_found
    invalid_limit_configuration
    no_effective_plan
    product_not_found
    product_not_in_plan
  ].freeze

  REASON_CODES = (OWN_REASON_CODES + ENTITLEMENT_DENIAL_REASON_CODES).freeze

  attr_reader :allowed,
    :reason_code,
    :message,
    :plan_key,
    :plan_source,
    :product_key,
    :feature_key,
    :feature_kind,
    :limit_value,
    :unlimited,
    :details

  def initialize(
    allowed:,
    reason_code:,
    message: nil,
    plan_key: nil,
    plan_source: nil,
    product_key: nil,
    feature_key: nil,
    feature_kind: nil,
    limit_value: nil,
    unlimited: false,
    details: {}
  )
    normalized_reason_code = normalize_reason_code(reason_code)
    validate_booleans!(allowed, unlimited)
    validate_outcome!(allowed, normalized_reason_code)

    @allowed = allowed
    @reason_code = normalized_reason_code
    @message = immutable_copy(message)
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
    allowed
  end

  def denied?
    !allowed?
  end

  def unlimited?
    unlimited
  end

  def capacity
    return unless allowed? && feature_kind == :limit

    unlimited? ? UNLIMITED : limit_value
  end

  private
    def normalize_reason_code(reason_code)
      normalized_reason_code = reason_code.to_sym
      return normalized_reason_code if REASON_CODES.include?(normalized_reason_code)

      raise ArgumentError, "unknown access reason code"
    rescue NoMethodError
      raise ArgumentError, "unknown access reason code"
    end

    def validate_booleans!(allowed, unlimited)
      return if [ true, false ].include?(allowed) && [ true, false ].include?(unlimited)

      raise ArgumentError, "allowed and unlimited must be booleans"
    end

    def validate_outcome!(allowed, reason_code)
      return if allowed == (reason_code == :access_granted)

      raise ArgumentError, "only access_granted may represent an allowed decision"
    end

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
