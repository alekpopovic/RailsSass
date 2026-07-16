class Organizations::DashboardController < Organizations::BaseController
  def show
    authorize Current.organization, :dashboard?
    @effective_plan = Current.organization.effective_plan
    @active_members_count = Current.organization.organization_memberships.active.count
    enabled_product_ids = Product.where(
      active: true,
      key: Entitlements::Resolver.new(organization: Current.organization).enabled_products
    ).select(:id)
    @active_product_memberships_count = Current.organization.product_memberships
      .active
      .where(product_id: enabled_product_ids)
      .count
  end
end
