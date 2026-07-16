class Access::ProductMemberships::Suspend < Access::ProductMemberships::Base
  def initialize(product_membership_id:)
    @product_membership_id = product_membership_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      next product_membership if product_membership.suspended?

      transition!(organization, product_membership, status: "suspended")
    end
  end
end
