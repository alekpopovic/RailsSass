class Admin::BaseController < ApplicationController
  ADMIN_PAGE_SIZE = 100
  ADMIN_MAX_PAGE = 10_000
  ADMIN_PAGE_PATTERN = /\A[1-9]\d{0,4}\z/
  AdminPage = Data.define(:records, :number, :has_next)

  before_action :authorize_platform_admin!

  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index

  private
    def authorize_platform_admin!
      authorize :platform_admin, :access?
    end

    def platform_scope(scope)
      policy_scope(scope, policy_scope_class: PlatformAdminPolicy::Scope)
    end

    def persist_catalog(record, attributes)
      Platform::PersistCatalog.new(
        actor: Current.user,
        record: record,
        attributes: attributes
      ).call
    end

    def paginate_admin(scope)
      page_number = admin_page_number
      records = scope
        .offset((page_number - 1) * ADMIN_PAGE_SIZE)
        .limit(ADMIN_PAGE_SIZE + 1)
        .to_a

      AdminPage.new(
        records: records.first(ADMIN_PAGE_SIZE),
        number: page_number,
        has_next: records.length > ADMIN_PAGE_SIZE
      )
    end

    def empty_admin_page
      AdminPage.new(records: [], number: admin_page_number, has_next: false)
    end

    def admin_page_number
      value = params.fetch(:page, "1").to_s
      raise ActiveRecord::RecordNotFound unless ADMIN_PAGE_PATTERN.match?(value)

      value.to_i.tap do |page_number|
        raise ActiveRecord::RecordNotFound if page_number > ADMIN_MAX_PAGE
      end
    end
end
