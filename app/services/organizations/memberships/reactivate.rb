class Organizations::Memberships::Reactivate < Organizations::Memberships::Base
  def initialize(actor:, membership_id:)
    initialize_context(actor: actor, membership_id: membership_id)
  end

  def call
    with_locked_memberships do |scope, actor_membership, target_membership|
      authorize_membership_management!(
        actor_membership,
        target_membership,
        allowed_statuses: %w[active suspended]
      )

      if target_membership.active?
        ensure_access_locator!(target_membership)
        target_membership
      else
        updated_membership = persist_transition!(scope, target_membership, status: "active")
        ensure_access_locator!(updated_membership)
        record_audit_event!(
          action: "organization.membership.reactivated",
          subject: updated_membership
        )
        updated_membership
      end
    end
  end
end
