class Access::ProductMemberships::UnassignRole < Access::ProductMemberships::Base
  def initialize(product_membership_id:, product_role_id:, actor: nil)
    initialize_actor(actor)
    @product_membership_id = product_membership_id
    @product_role_id = product_role_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      authorize_actor_for_product!(organization, product_membership.product_id)
      assignment = product_membership.product_membership_roles
        .where(product_role_id: @product_role_id)
        .lock
        .first!
      product_role = ProductRole.where(
        id: assignment.product_role_id,
        product_id: product_membership.product_id
      ).first!

      record_audit_event!(
        action: "product.membership.role_unassigned",
        subject: product_membership,
        metadata: audit_metadata(product_membership, product_role: product_role)
      )
      assignment.destroy!
    end
  end
end
