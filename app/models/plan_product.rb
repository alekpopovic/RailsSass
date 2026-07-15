class PlanProduct < ApplicationRecord
  belongs_to :plan, inverse_of: :plan_products
  belongs_to :product, inverse_of: :plan_products

  has_many :plan_feature_entitlements,
    dependent: :restrict_with_exception,
    inverse_of: :plan_product

  attr_readonly :plan_id, :product_id

  validates :product_id, uniqueness: { scope: :plan_id }
end
