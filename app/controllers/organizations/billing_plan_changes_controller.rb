class Organizations::BillingPlanChangesController < Organizations::BaseController
  rate_limit to: 5, within: 10.minutes, only: :create, name: "billing-plan-change-create",
    by: -> { "#{Current.user.id}:#{Current.organization.id}" },
    with: -> { redirect_to_billing(alert: "Please wait before requesting another plan change.") }

  before_action :set_no_store_headers

  def create
    authorize Current.organization, :change_plan?
    plan_price = PlanPrice.find(params.expect(:plan_price_id))
    result = Billing::PlanChanges::Create.new(
      organization: Current.organization,
      user: Current.user,
      plan_price: plan_price,
      compatibility_checker: Products::PlanCompatibility
    ).call

    message = if result.duplicate?
      "That plan change is already pending provider confirmation."
    elsif result.plan_change.status_applied?
      "The verified billing event has already confirmed this plan change."
    else
      "Plan change submitted. Access will update only after a verified billing event."
    end
    redirect_to_billing(notice: message)
  rescue ActiveRecord::RecordNotFound, Billing::PlanChanges::Create::InvalidPrice
    redirect_to_billing(alert: "That plan option is unavailable.")
  rescue Billing::PlanChanges::Create::NoSubscription
    redirect_to_billing(alert: "There is no synchronized subscription available to change.")
  rescue Billing::PlanChanges::Create::ChangePending
    redirect_to_billing(alert: "Another plan change is already pending provider confirmation.")
  rescue Billing::PlanChanges::Create::IncompatiblePlan
    redirect_to_billing(alert: "This change is blocked because current usage exceeds the selected plan limits.")
  rescue Billing::PlanChanges::Create::ProviderFailure => error
    message = if error.ambiguous?
      "The provider result is not yet known. Do not retry while this change is pending."
    else
      "The provider rejected the plan change. Your current plan remains unchanged."
    end
    redirect_to_billing(alert: message)
  rescue Billing::LemonSqueezy::Errors::Error
    redirect_to_billing(alert: "Plan changes are temporarily unavailable. Please try again later.")
  end

  private
    def set_no_store_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def redirect_to_billing(notice: nil, alert: nil)
      redirect_to organization_billing_path(organization_slug: Current.organization.slug),
        status: :see_other,
        notice: notice,
        alert: alert
    end
end
