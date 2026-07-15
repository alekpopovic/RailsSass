class Organizations::Memberships::Remove < Organizations::Memberships::Base
  def initialize(actor:, membership_id:)
    initialize_context(actor: actor, membership_id: membership_id)
  end

  def call
    with_locked_memberships do |scope, actor_membership, target_membership|
      authorize_membership_management!(actor_membership, target_membership)
      ensure_another_active_owner!(scope, target_membership)
      Current.organization.organization_access_locators
        .where(organization_membership_id: target_membership.id)
        .delete_all
      persist_transition!(scope, target_membership, status: "suspended")
    end
  end
end
