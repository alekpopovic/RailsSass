class Access::ProductMemberships::Add < Access::ProductMemberships::Base
  def initialize(organization_membership_id:, product_id:)
    @organization_membership_id = organization_membership_id
    @product_id = product_id
  end

  def call
    with_locked_organization do |organization|
      organization_membership = locked_active_organization_membership!(
        organization,
        @organization_membership_id
      )
      product = locked_active_product!(@product_id)
      product_membership = organization.product_memberships.lock.find_by(
        organization_membership_id: organization_membership.id,
        product_id: product.id
      )

      if product_membership
        invalid_record!(product_membership, "must be reactivated") unless product_membership.active?
        next product_membership
      end

      organization.product_memberships.create!(
        organization_membership: organization_membership,
        product: product,
        status: :active
      )
    end
  end
end
