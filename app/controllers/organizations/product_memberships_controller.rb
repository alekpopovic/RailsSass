class Organizations::ProductMembershipsController < Organizations::BaseController
  rescue_from ActiveRecord::RecordInvalid, with: :redirect_invalid_product_membership

  before_action :set_product
  before_action :set_product_membership,
    only: %i[destroy suspend reactivate assign_role unassign_role]
  after_action :verify_policy_scoped, only: :index

  def index
    @product_scope_record = Current.organization.product_memberships.new(product: @product)
    authorize @product_scope_record, :index?
    load_index_data
  end

  def create
    organization_membership = Current.organization.organization_memberships.active.find(
      product_membership_params.fetch(:organization_membership_id)
    )
    @product_membership = Current.organization.product_memberships.new(
      organization_membership: organization_membership,
      product: @product
    )
    authorize @product_membership, :create?

    Access::ProductMemberships::Add.new(
      organization_membership_id: organization_membership.id,
      product_id: @product.id,
      actor: Current.user
    ).call

    redirect_to_members notice: "Product member added."
  rescue ActiveRecord::RecordInvalid => error
    @product_membership = error.record
    load_index_data
    render :index, status: :unprocessable_content
  end

  def destroy
    authorize @product_membership, :destroy?
    Access::ProductMemberships::Remove.new(
      product_membership_id: @product_membership.id,
      actor: Current.user
    ).call

    redirect_to_members notice: "Product member removed."
  end

  def suspend
    authorize @product_membership, :suspend?
    Access::ProductMemberships::Suspend.new(
      product_membership_id: @product_membership.id,
      actor: Current.user
    ).call

    redirect_to_members notice: "Product member suspended."
  end

  def reactivate
    authorize @product_membership, :reactivate?
    Access::ProductMemberships::Reactivate.new(
      product_membership_id: @product_membership.id,
      actor: Current.user
    ).call

    redirect_to_members notice: "Product member reactivated."
  end

  def assign_role
    authorize @product_membership, :assign_role?
    product_role = active_system_roles.find_by!(key: normalized_role_key)
    Access::ProductMemberships::AssignRole.new(
      product_membership_id: @product_membership.id,
      product_role_id: product_role.id,
      actor: Current.user
    ).call

    redirect_to_members notice: "Product role assigned."
  end

  def unassign_role
    authorize @product_membership, :unassign_role?
    product_role = @product_membership.product_roles.find_by!(
      product_id: @product.id,
      organization_id: nil,
      system: true,
      key: normalized_role_key
    )
    Access::ProductMemberships::UnassignRole.new(
      product_membership_id: @product_membership.id,
      product_role_id: product_role.id,
      actor: Current.user
    ).call

    redirect_to_members notice: "Product role unassigned."
  end

  private
    def set_product
      @tenant_organization = Current.organization
      product_key = Product.normalize_value_for(:key, params[:product_key])
      @product = Product.find_by!(key: product_key)
    end

    def set_product_membership
      @product_membership = Current.organization.product_memberships
        .where(product_id: @product.id)
        .find(params[:id])
    end

    def load_index_data
      product_memberships = Current.organization.product_memberships.where(
        product_id: @product.id
      )
      @product_memberships = policy_scope(product_memberships)
        .includes(organization_membership: :user, product_membership_roles: :product_role)
        .joins(organization_membership: :user)
        .order("users.name", "product_memberships.id")
      @available_memberships = Current.organization.organization_memberships
        .active
        .includes(:user)
        .where.not(id: product_memberships.select(:organization_membership_id))
        .joins(:user)
        .order("users.name", "organization_memberships.id")
      @system_roles = active_system_roles.order(:name, :id)
      @seat_usage = Entitlements::LimitEnforcer.new(
        organization: Current.organization,
        product_key: @product.key,
        feature_key: Entitlements::Usage::SEAT_FEATURE_KEY
      ).status
    end

    def active_system_roles
      @product.product_roles.where(
        organization_id: nil,
        system: true,
        active: true
      )
    end

    def product_membership_params
      params.expect(product_membership: [ :organization_membership_id ])
    end

    def normalized_role_key
      ProductRole.normalize_value_for(:key, params.expect(:role_key))
    end

    def redirect_to_members(notice:)
      redirect_to organization_product_members_path(
        organization_slug: @tenant_organization.slug,
        product_key: @product.key
      ), status: :see_other, notice: notice
    end

    def redirect_invalid_product_membership(error)
      redirect_to organization_product_members_path(
        organization_slug: @tenant_organization.slug,
        product_key: @product.key
      ), status: :see_other, alert: error.record.errors.full_messages.to_sentence
    end
end
