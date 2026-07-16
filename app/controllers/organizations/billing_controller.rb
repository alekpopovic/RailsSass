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
  end
end
