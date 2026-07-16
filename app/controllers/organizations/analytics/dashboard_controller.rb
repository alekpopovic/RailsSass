class Organizations::Analytics::DashboardController < Organizations::BaseController
  def show
    authorize :analytics_dashboard,
      :show?,
      policy_class: Products::Analytics::DashboardPolicy

    @reports_decision = analytics_decision(:report_read)
    @create_decision = analytics_decision(:report_create)
    @report_count = Current.organization.analytics_reports.count if @reports_decision.allowed?
  end

  private
    def analytics_decision(action)
      Products::Analytics::ActionRegistry.decision(
        action,
        context: AuthorizationContext.current
      )
    end
end
