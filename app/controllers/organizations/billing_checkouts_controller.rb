class Organizations::BillingCheckoutsController < Organizations::BaseController
  rate_limit to: 5, within: 10.minutes, only: :create, name: "billing-checkout-create",
    by: -> { "#{Current.user.id}:#{Current.organization.id}" },
    with: -> { redirect_to_pending(alert: "Please wait before starting another checkout.") }

  before_action :set_no_store_headers

  def create
    authorize Current.organization, :checkout?
    plan_price = PlanPrice.find(params.expect(:plan_price_id))
    result = Billing::Checkouts::Create.new(
      organization: Current.organization,
      user: Current.user,
      plan_price: plan_price
    ).call

    redirect_to_provider_without_logging(result.checkout_url)
  rescue Billing::Checkouts::Create::InvalidPrice, ActiveRecord::RecordNotFound
    redirect_to_pricing(alert: "That checkout option is unavailable.")
  rescue Billing::Checkouts::Create::ExistingSubscription
    redirect_to organization_billing_path(organization_slug: Current.organization.slug),
      status: :see_other,
      alert: "Use the billing page to manage the current subscription."
  rescue Billing::Checkouts::Create::CheckoutPending
    redirect_to_pending(alert: "A checkout is already pending for this organization.")
  rescue Billing::Checkouts::Create::ProviderFailure => error
    if error.ambiguous?
      redirect_to_pending(
        alert: "We could not confirm checkout creation. Do not retry while this attempt is pending."
      )
    else
      redirect_to_pricing(alert: "Checkout is temporarily unavailable. Please try again later.")
    end
  rescue Billing::LemonSqueezy::Errors::Error
    redirect_to_pricing(alert: "Checkout is temporarily unavailable. Please try again later.")
  end

  def pending
    authorize Current.organization, :checkout?
    @attempt = Current.organization.billing_checkout_attempts
      .includes(plan_price: :plan)
      .order(created_at: :desc, id: :desc)
      .first
    @subscription = Current.organization.billing_subscriptions
      .includes(plan_price: :plan)
      .find_by(current: true)
  end

  private
    def set_no_store_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def redirect_to_provider_without_logging(checkout_url)
      response.status = :see_other
      response.set_header("Location", checkout_url)
      self.response_body = ""
    end

    def redirect_to_pending(alert:)
      redirect_to organization_billing_checkout_pending_path(
        organization_slug: Current.organization.slug
      ), status: :see_other, alert: alert
    end

    def redirect_to_pricing(alert:)
      redirect_to organization_pricing_path(organization_slug: Current.organization.slug),
        status: :see_other,
        alert: alert
    end
end
