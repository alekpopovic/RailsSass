require "test_helper"
require_relative "../support/organization_test_helper"

class CreateAnalyticsReportsTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  test "installs required columns checks indexes and a restricted organization foreign key" do
    columns = AnalyticsReport.columns.index_by(&:name)
    %w[organization_id public_id name description created_at updated_at].each do |column_name|
      assert_not columns.fetch(column_name).null,
        "expected analytics_reports.#{column_name} to be NOT NULL"
    end

    constraint_names = AnalyticsReport.connection
      .check_constraints(:analytics_reports)
      .map(&:name)
    assert_includes constraint_names, "analytics_reports_name_normalized"
    assert_includes constraint_names, "analytics_reports_description_normalized"

    indexes = AnalyticsReport.connection.indexes(:analytics_reports).index_by(&:name)
    assert_predicate indexes.fetch("index_analytics_reports_on_public_id"), :unique
    assert_equal %w[organization_id created_at id],
      indexes.fetch("index_analytics_reports_on_org_created_at_and_id").columns

    organization_foreign_key = AnalyticsReport.connection
      .foreign_keys(:analytics_reports)
      .find { |foreign_key| foreign_key.to_table == "organizations" }
    assert_equal :restrict, organization_foreign_key.on_delete
  end

  test "database rejects invalid ownership duplicate public IDs and unnormalized content" do
    owner = create_test_user(email_address: "analytics-db-owner@example.test")
    organization, = create_test_organization_with_owner(
      owner: owner,
      name: "Analytics Database",
      slug: "analytics-database"
    )
    public_id = SecureRandom.uuid
    AnalyticsReport.insert_all!([ raw_attributes(
      organization_id: organization.id,
      public_id: public_id
    ) ])

    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      AnalyticsReport.insert_all!([ raw_attributes(
        organization_id: organization.id,
        public_id: public_id
      ) ])
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      execute_raw_update(public_id: public_id, attribute: :name, value: " Padded name ")
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      execute_raw_update(public_id: public_id, attribute: :description, value: "x" * 2_001)
    end
    assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      AnalyticsReport.insert_all!([ raw_attributes(organization_id: -1) ])
    end
  end

  private
    def raw_attributes(**overrides)
      now = Time.current
      {
        organization_id:,
        public_id: SecureRandom.uuid,
        name: "Database report",
        description: "Synthetic report.",
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def organization_id
      Organization.first&.id || raise("an organization is required")
    end

    def assert_database_error(exception_class, cause_class, &block)
      error = assert_raises(exception_class) do
        ApplicationRecord.transaction(requires_new: true, &block)
      end
      assert_kind_of cause_class, error.cause
    end

    def execute_raw_update(public_id:, attribute:, value:)
      sql = AnalyticsReport.sanitize_sql_array([ "UPDATE analytics_reports SET #{attribute} = ? WHERE public_id = ?", value, public_id ])
      AnalyticsReport.connection.execute(sql)
    end
end
