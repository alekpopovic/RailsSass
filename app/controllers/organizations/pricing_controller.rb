class Organizations::PricingController < Organizations::BaseController
  def index
    authorize Current.organization, :pricing?
    @effective_plan = Current.organization.effective_plan
    @plans = Plan.where(active: true).order(:position, :id).load
    plan_ids = @plans.map(&:id)
    @active_products_by_plan_id = PlanProduct
      .joins(:product)
      .merge(Product.where(active: true))
      .where(plan_id: plan_ids)
      .includes(:product)
      .order("products.name", "products.id")
      .group_by(&:plan_id)
      .transform_values { |rows| rows.map(&:product) }
    @active_prices_by_plan_id = PlanPrice
      .where(plan_id: plan_ids, active: true)
      .order(:billing_interval, :amount_cents, :id)
      .group_by(&:plan_id)
  end
end
