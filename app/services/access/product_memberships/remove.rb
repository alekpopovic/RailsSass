class Access::ProductMemberships::Remove < Access::ProductMemberships::Base
  def initialize(product_membership_id:, actor: nil)
    initialize_actor(actor)
    @product_membership_id = product_membership_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      authorize_actor_for_product!(organization, product_membership.product_id)
      record_audit_event!(
        action: "product.membership.removed",
        subject: product_membership,
        metadata: audit_metadata(product_membership)
      )
      product_membership.destroy!
    end
  end
end
