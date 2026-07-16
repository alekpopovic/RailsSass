class Admin::Billing::WebhookEventsController < Admin::BaseController
  def index
    @webhook_events_page = paginate_admin(
      failed_events.order(received_at: :desc, id: :desc)
    )
  end

  def show
    @webhook_event = failed_events.find(params[:id])
  end

  private
    def failed_events
      platform_scope(Billing::WebhookEvent.where(status: "failed"))
    end
end
