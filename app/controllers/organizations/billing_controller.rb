class Organizations::BillingController < Organizations::BaseController
  def show
    authorize Current.organization, :billing?
    @subscription = Current.organization.billing_subscriptions
      .includes(plan_price: :plan)
      .find_by(current: true)
    @effective_plan = Current.organization.effective_plan
    @subscription_access = Entitlements::SubscriptionAccessPolicy.new(
      subscription: @subscription
    ).call
    @current_compatibility = if @effective_plan
      Products::PlanCompatibility.call(
        organization: Current.organization,
        to_plan: @effective_plan
      )
    end
    @latest_plan_change = Current.organization.billing_plan_changes
      .includes(from_plan_price: :plan, to_plan_price: :plan)
      .order(requested_at: :desc, id: :desc)
      .first
    @open_plan_change = Current.organization.billing_plan_changes
      .open
      .includes(to_plan_price: :plan)
      .order(requested_at: :desc, id: :desc)
      .first
    @plan_change_options = plan_change_options
  end

  private
    def plan_change_options
      return [] unless @subscription&.sync_state_synced?

      source_price = @subscription.plan_price
      mappings = Billing::ProviderPriceMapping
        .joins(plan_price: :plan)
        .includes(plan_price: :plan)
        .where(
          provider: @subscription.provider,
          environment: @subscription.environment,
          provider_store_id: source_price.lemon_store_id,
          active: true
        )
        .where.not(plan_price_id: source_price.id)
        .order("plan_prices.amount_cents", "plan_prices.id")

      mappings.filter_map do |mapping|
        price = mapping.plan_price
        next unless mapping.checkout_eligible?

        compatibility = Products::PlanCompatibility.call(
          organization: Current.organization,
          from_plan: source_price.plan,
          to_plan: price.plan
        )
        [ price, compatibility ]
      end
    end
end
