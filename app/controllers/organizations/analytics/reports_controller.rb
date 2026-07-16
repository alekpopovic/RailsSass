class Organizations::Analytics::ReportsController < Organizations::BaseController
  before_action :set_report, only: %i[show export]
  after_action :verify_policy_scoped, only: :index

  def index
    authorize AnalyticsReport,
      :index?,
      policy_class: Products::Analytics::ReportPolicy
    @reports = policy_scope(
      Current.organization.analytics_reports,
      policy_scope_class: Products::Analytics::ReportPolicy::Scope
    ).order(created_at: :desc, id: :desc)
    set_action_decisions
  end

  def new
    @report = Current.organization.analytics_reports.new
    authorize_report(@report, :create?)
    @create_decision = analytics_decision(:report_create)
    set_report_usage
  end

  def create
    @report = Current.organization.analytics_reports.new(report_params)
    authorize_report(@report, :create?)
    @report = Products::Analytics::CreateReport.new(
      context: AuthorizationContext.current,
      attributes: report_params
    ).call

    redirect_to organization_analytics_report_path(
      organization_slug: Current.organization.slug,
      public_id: @report.public_id
    ), status: :see_other, notice: "Report created."
  rescue ActiveRecord::RecordInvalid => error
    @report = error.record
    @create_decision = analytics_decision(:report_create)
    set_report_usage
    render :new, status: :unprocessable_entity
  end

  def show
    authorize_report(@report, :show?)
    @export_decision = analytics_decision(:export_run)
  end

  def export
    authorize_report(@report, :export?)
    csv = Products::Analytics::CsvExporter.new(@report).call

    send_data csv,
      filename: "analytics-report-#{@report.public_id}.csv",
      type: "text/csv; charset=utf-8",
      disposition: "attachment"
  end

  private
    def set_report
      @report = Current.organization.analytics_reports.find_by!(
        public_id: params[:public_id]
      )
    end

    def report_params
      params.expect(analytics_report: %i[name description])
    end

    def authorize_report(report, query)
      authorize report, query, policy_class: Products::Analytics::ReportPolicy
    end

    def analytics_decision(action)
      Products::Analytics::ActionRegistry.decision(
        action,
        context: AuthorizationContext.current
      )
    end

    def set_action_decisions
      @create_decision = analytics_decision(:report_create)
      @export_decision = analytics_decision(:export_run)
      set_report_usage
    end

    def set_report_usage
      @report_usage = Entitlements::LimitEnforcer.new(
        organization: Current.organization,
        product_key: Products::Analytics::ActionRegistry::PRODUCT_KEY,
        feature_key: "report_limit"
      ).status
    end
end
