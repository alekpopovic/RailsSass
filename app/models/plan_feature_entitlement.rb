require "json"

class PlanFeatureEntitlement < ApplicationRecord
  SETTINGS_MAX_BYTES = 65_536
  SETTINGS_MAX_DEPTH = 20
  SAFE_SETTINGS_KEYS = %w[token_bucket_size].freeze
  SENSITIVE_SETTINGS_KEY_PATTERN = /(?:\A|_)(?:
    api_key|apikey|access_key|secret_key|private_key|authorization|credential|credentials|
    token|password|secret|signature|card_number|cvc|cvv|email|email_address|
    signed_url|checkout_url|portal_url
  )(?:\z|_)/x

  belongs_to :plan_product, inverse_of: :plan_feature_entitlements
  belongs_to :product_feature, inverse_of: :plan_feature_entitlements
  belongs_to :product, inverse_of: :plan_feature_entitlements

  enum :feature_kind,
    { flag: "flag", limit: "limit" },
    validate: true,
    scopes: false

  before_validation :derive_integrity_attributes, on: :create

  attr_readonly :plan_product_id, :product_feature_id, :product_id, :feature_kind

  validates :product_feature_id, uniqueness: { scope: :plan_product_id }
  validates :enabled, :unlimited, inclusion: { in: [ true, false ] }
  validates :limit_value,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    allow_nil: true
  validate :feature_belongs_to_plan_product
  validate :typed_value_is_valid
  validate :settings_is_a_bounded_object

  private
    def derive_integrity_attributes
      self.product_id = plan_product&.product_id
      self.feature_kind = product_feature&.kind
    end

    def feature_belongs_to_plan_product
      return if plan_product.blank? || product_feature.blank?
      return if plan_product.product_id == product_feature.product_id

      errors.add(:product_feature, "must belong to the plan product")
    end

    def typed_value_is_valid
      case feature_kind
      when "flag"
        errors.add(:limit_value, "must be blank for a flag feature") if limit_value.present?
        errors.add(:unlimited, "must be false for a flag feature") if unlimited?
      when "limit"
        if unlimited?
          errors.add(:limit_value, "must be blank when unlimited") if limit_value.present?
        elsif limit_value.blank?
          errors.add(:limit_value, "must be present unless unlimited")
        end
      end
    end

    def settings_is_a_bounded_object
      unless settings.is_a?(Hash)
        errors.add(:settings, "must be an object")
        return
      end

      serialized_settings = JSON.generate(settings, max_nesting: SETTINGS_MAX_DEPTH)
      if serialized_settings.bytesize > SETTINGS_MAX_BYTES ||
          jsonb_storage_bytes(serialized_settings) > SETTINGS_MAX_BYTES
        errors.add(:settings, "must be at most 64 KiB")
      end
      if nested_settings_keys(settings).any? { |key| sensitive_settings_key?(key) }
        errors.add(:settings, "contains a sensitive field")
      end
    rescue JSON::NestingError, SystemStackError
      errors.add(:settings, "must be at most 20 levels deep")
    rescue JSON::GeneratorError
      errors.add(:settings, "must contain only JSON values")
    end

    def nested_settings_keys(value, depth = 0)
      raise JSON::NestingError, "settings nesting is too deep" if depth > SETTINGS_MAX_DEPTH

      case value
      when Hash
        value.each_with_object([]) do |(key, nested_value), keys|
          keys << normalize_settings_key(key)
          keys.concat(nested_settings_keys(nested_value, depth + 1))
        end
      when Array
        value.flat_map { |nested_value| nested_settings_keys(nested_value, depth + 1) }
      else
        []
      end
    end

    def normalize_settings_key(key)
      key.to_s
        .strip
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .gsub(/[^a-zA-Z\d]+/, "_")
        .gsub(/\A_+|_+\z/, "")
        .downcase
    end

    def jsonb_storage_bytes(serialized_settings)
      bind = ActiveRecord::Relation::QueryAttribute.new(
        "settings",
        serialized_settings,
        ActiveRecord::Type::String.new
      )
      self.class.connection.select_value(
        "SELECT pg_column_size($1::jsonb)",
        "PlanFeatureEntitlement settings size",
        [ bind ]
      ).to_i
    end

    def sensitive_settings_key?(key)
      !SAFE_SETTINGS_KEYS.include?(key) && SENSITIVE_SETTINGS_KEY_PATTERN.match?(key)
    end
end
