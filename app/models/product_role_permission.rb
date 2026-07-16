class ProductRolePermission < ApplicationRecord
  belongs_to :product, inverse_of: :product_role_permissions
  belongs_to :product_role, inverse_of: :product_role_permissions
  belongs_to :product_permission, inverse_of: :product_role_permissions

  before_validation :derive_product, on: :create

  attr_readonly :product_id, :product_role_id, :product_permission_id

  validates :product_permission_id, uniqueness: { scope: :product_role_id }
  validate :records_belong_to_same_product
  validate :role_accepts_new_permissions, on: :create

  private
    def derive_product
      self.product ||= product_role&.product
    end

    def records_belong_to_same_product
      return if product.blank? || product_role.blank? || product_permission.blank?
      return if product_role.product_id == product.id && product_permission.product_id == product.id

      errors.add(:product, "must match the role and permission product")
    end

    def role_accepts_new_permissions
      return if product_role.blank? || product_role.active?

      errors.add(:product_role, "must be active for a new permission mapping")
    end
end
