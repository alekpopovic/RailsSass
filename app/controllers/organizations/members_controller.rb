class Organizations::MembersController < Organizations::BaseController
  after_action :verify_policy_scoped

  def index
    authorize Current.organization, :members?
    @memberships = policy_scope(
      Current.organization.organization_memberships.includes(:user)
    ).order(:joined_at, :id)
  end
end
