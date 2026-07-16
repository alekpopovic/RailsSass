class Access::ProductMemberships::AssignRole < Access::ProductMemberships::Base
  def initialize(product_membership_id:, product_role_id:, actor: nil)
    initialize_actor(actor)
    @product_membership_id = product_membership_id
    @product_role_id = product_role_id
  end

  def call
    with_locked_organization do |organization|
      product_membership = locked_product_membership!(organization, @product_membership_id)
      invalid_record!(product_membership, "must be active") unless product_membership.active?
      locked_active_organization_membership!(
        organization,
        product_membership.organization_membership_id
      )
      locked_active_product!(product_membership.product_id)
      authorize_actor_for_product!(organization, product_membership.product_id)
      product_role = locked_assignable_role!(organization, product_membership)

      assignment = product_membership.product_membership_roles.lock.find_by(
        product_role_id: product_role.id
      )
      next assignment if assignment

      assignment = product_membership.product_membership_roles.create!(
          organization: organization,
          product_id: product_membership.product_id,
          product_role: product_role
        )
      record_audit_event!(
        action: "product.membership.role_assigned",
        subject: product_membership,
        metadata: audit_metadata(product_membership, product_role: product_role)
      )
      assignment
    end
  end

  private
    def locked_assignable_role!(organization, product_membership)
      product_role = ProductRole
        .where(
          id: @product_role_id,
          product_id: product_membership.product_id,
          organization_id: nil,
          system: true,
          active: true
        )
        .lock
        .first
      product_role ||= organization.product_roles
        .where(
          id: @product_role_id,
          product_id: product_membership.product_id,
          system: false,
          active: true
        )
        .lock
        .first

      product_role || raise(ActiveRecord::RecordNotFound, "product role not found")
    end
end
