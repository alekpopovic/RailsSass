class Organizations::MembersController < Organizations::BaseController
  before_action :set_membership, only: %i[update suspend reactivate]
  after_action :verify_policy_scoped, only: :index

  def index
    authorize Current.organization, :members?
    @memberships = policy_scope(
      Current.organization.organization_memberships.includes(:user)
    ).order(:joined_at, :id)
    @invitations = policy_scope(
      Current.organization.organization_invitations.includes(:inviter)
    ).order(created_at: :desc, id: :desc)
  end

  def update
    authorize @membership, :change_role?
    self_membership = @membership.id == Current.membership.id
    Organizations::Memberships::ChangeRole.new(
      actor: Current.user,
      membership_id: @membership.id,
      role: membership_params[:role]
    ).call

    redirect_after_membership_change(
      self_membership: self_membership,
      notice: "Member role updated."
    )
  rescue ActiveRecord::RecordInvalid => error
    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      alert: error.record.errors.full_messages.to_sentence
  end

  def suspend
    authorize @membership, :suspend?
    self_membership = @membership.id == Current.membership.id
    Organizations::Memberships::Remove.new(
      actor: Current.user,
      membership_id: @membership.id
    ).call

    destination = if self_membership
      root_path
    else
      organization_members_path(organization_slug: Current.organization.slug)
    end
    redirect_to destination, status: :see_other, notice: "Member suspended."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      alert: error.record.errors.full_messages.to_sentence
  end

  def reactivate
    authorize @membership, :reactivate?
    Organizations::Memberships::Reactivate.new(
      actor: Current.user,
      membership_id: @membership.id
    ).call

    redirect_to organization_members_path(organization_slug: Current.organization.slug),
      status: :see_other,
      notice: "Member reactivated."
  end

  private
    def set_membership
      @membership = Current.organization.organization_memberships.find(params[:id])
    end

    def membership_params
      params.expect(organization_membership: [ :role ])
    end

    def redirect_after_membership_change(self_membership:, notice:)
      destination = if self_membership
        organization_dashboard_path(organization_slug: Current.organization.slug)
      else
        organization_members_path(organization_slug: Current.organization.slug)
      end

      redirect_to destination, status: :see_other, notice: notice
    end
end
