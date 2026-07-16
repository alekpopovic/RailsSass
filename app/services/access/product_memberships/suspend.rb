class Access::ProductMemberships::Suspend < Access::ProductMemberships::Base
  def initialize(product_membership_id:, actor: nil)
    initialize_actor(actor)
    @product_membership_id = product_membership_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      authorize_actor_for_product!(organization, product_membership.product_id)
      next product_membership if product_membership.suspended?

      suspended_membership = transition!(organization, product_membership, status: "suspended")
      record_audit_event!(
        action: "product.membership.suspended",
        subject: suspended_membership,
        metadata: audit_metadata(suspended_membership)
      )
      suspended_membership
    end
  end
end
