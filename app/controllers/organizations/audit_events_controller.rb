class Organizations::AuditEventsController < Organizations::BaseController
  PAGE_SIZE = 50
  MAX_PAGE = 10_000
  PAGE_PATTERN = /\A[1-9]\d{0,4}\z/
  AuditEventsPage = Data.define(:records, :number, :has_next)

  after_action :verify_policy_scoped, only: :index

  def index
    authorize AuditEvent, :index?
    @audit_events_page = paginate(
      policy_scope(Current.organization.audit_events.includes(:actor_user))
        .order(created_at: :desc, id: :desc)
    )
  end

  private
    def paginate(scope)
      number = page_number
      records = scope
        .offset((number - 1) * PAGE_SIZE)
        .limit(PAGE_SIZE + 1)
        .to_a

      AuditEventsPage.new(
        records: records.first(PAGE_SIZE),
        number: number,
        has_next: records.length > PAGE_SIZE
      )
    end

    def page_number
      value = params.fetch(:page, "1").to_s
      raise ActiveRecord::RecordNotFound unless PAGE_PATTERN.match?(value)

      value.to_i.tap do |number|
        raise ActiveRecord::RecordNotFound if number > MAX_PAGE
      end
    end
end
