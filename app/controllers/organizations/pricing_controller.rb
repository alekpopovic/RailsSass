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
      .includes(:plan)
      .order(:billing_interval, :amount_cents, :id)
      .group_by(&:plan_id)
    price_ids = @active_prices_by_plan_id.values.flatten.map(&:id)
    @checkout_mappings_by_plan_price_id = Billing::ProviderPriceMapping
      .includes(plan_price: :plan)
      .where(
        plan_price_id: price_ids,
        environment: Rails.configuration.x.billing.lemon_squeezy.environment,
        provider_store_id: Rails.configuration.x.billing.lemon_squeezy.store_id,
        active: true
      )
      .index_by(&:plan_price_id)
    @can_checkout = policy(Current.organization).checkout?
    @current_subscription = Current.organization.billing_subscriptions.find_by(current: true)
    @pending_checkout_attempt = Current.organization.billing_checkout_attempts.pending.exists?
  end
end
