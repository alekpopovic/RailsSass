class Access::ProductMemberships::Reactivate < Access::ProductMemberships::Base
  def initialize(product_membership_id:)
    @product_membership_id = product_membership_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      locked_active_organization_membership!(
        organization,
        product_membership.organization_membership_id
      )
      locked_active_product!(product_membership.product_id)
      next product_membership if product_membership.active?

      transition!(organization, product_membership, status: "active")
    end
  end
end
