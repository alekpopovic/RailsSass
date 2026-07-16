class Organizations::Analytics::DashboardController < Organizations::BaseController
  def show
    authorize :analytics_dashboard,
      :show?,
      policy_class: Products::Analytics::DashboardPolicy

    @reports_decision = analytics_decision(:report_read)
    @create_decision = analytics_decision(:report_create)
    @report_usage = Entitlements::LimitEnforcer.new(
      organization: Current.organization,
      product_key: Products::Analytics::ActionRegistry::PRODUCT_KEY,
      feature_key: "report_limit"
    ).status if @reports_decision.allowed?
  end

  private
    def analytics_decision(action)
      Products::Analytics::ActionRegistry.decision(
        action,
        context: AuthorizationContext.current
      )
    end
end
