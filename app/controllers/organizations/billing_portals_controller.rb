class Organizations::BillingPortalsController < Organizations::BaseController
  rate_limit to: 10, within: 10.minutes, only: :create, name: "billing-portal-create",
    by: -> { "#{Current.user.id}:#{Current.organization.id}" },
    with: -> { redirect_to_billing(alert: "Please wait before requesting another portal link.") }

  before_action :set_no_store_headers

  def create
    authorize Current.organization, :portal?
    portal_url = Billing::Portals::Open.new(
      organization: Current.organization,
      user: Current.user
    ).call

    redirect_to_provider_without_logging(portal_url)
  rescue Billing::Portals::Open::NoSubscription,
      Billing::Portals::Open::Unavailable,
      Billing::Portals::Open::ProviderFailure
    redirect_to_billing(alert: "The customer portal is temporarily unavailable. Please try again later.")
  end

  private
    def set_no_store_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def redirect_to_provider_without_logging(portal_url)
      response.status = :see_other
      response.set_header("Location", portal_url)
      self.response_body = ""
    end

    def redirect_to_billing(alert:)
      redirect_to organization_billing_path(organization_slug: Current.organization.slug),
        status: :see_other,
        alert: alert
    end
end
