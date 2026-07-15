class PlanFeatureEntitlement < ApplicationRecord
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
  validate :settings_is_an_object

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

    def settings_is_an_object
      errors.add(:settings, "must be an object") unless settings.is_a?(Hash)
    end
end
