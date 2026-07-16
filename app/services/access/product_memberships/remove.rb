class Access::ProductMemberships::Remove < Access::ProductMemberships::Base
  def initialize(product_membership_id:)
    @product_membership_id = product_membership_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      product_membership.destroy!
    end
  end
end
