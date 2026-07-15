class Organizations::Memberships::ChangeRole < Organizations::Memberships::Base
  def initialize(actor:, membership_id:, role:)
    initialize_context(actor: actor, membership_id: membership_id)
    @role = role.to_s
  end

  def call
    with_locked_memberships do |scope, actor_membership, target_membership|
      validate_role!(target_membership)
      authorize_membership_management!(actor_membership, target_membership, new_role: @role)

      if target_membership.role == @role
        target_membership
      else
        ensure_another_active_owner!(scope, target_membership) unless @role == "owner"
        persist_transition!(scope, target_membership, role: @role)
      end
    end
  end

  private
    def validate_role!(target_membership)
      return if OrganizationMembership.roles.key?(@role)

      target_membership.errors.add(:role, :inclusion)
      raise ActiveRecord::RecordInvalid, target_membership
    end
end
