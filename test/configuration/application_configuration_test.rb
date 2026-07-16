require "test_helper"

class ApplicationConfigurationTest < ActiveSupport::TestCase
  test "uses Belgrade application time and UTC database timestamps" do
    assert_equal "Europe/Belgrade", Rails.application.config.time_zone
    assert_equal :utc, ActiveRecord.default_timezone
  end

  test "maps Pundit authorization failures to forbidden" do
    rescue_responses = Rails.application.config.action_dispatch.rescue_responses

    assert_equal :forbidden, rescue_responses.fetch("Pundit::NotAuthorizedError")
  end

  test "uses SQL schema only for the primary PostgreSQL database" do
    schema_formats = ActiveRecord::Base.configurations
      .configs_for(env_name: "production")
      .to_h { |configuration| [ configuration.name, configuration.schema_format ] }

    assert_equal :sql, schema_formats.fetch("primary")
    assert_equal :ruby, schema_formats.fetch("cache")
    assert_equal :ruby, schema_formats.fetch("queue")
    assert_equal :ruby, schema_formats.fetch("cable")
  end

  test "does not auto-seed the test database during database prepare" do
    test_database = ActiveRecord::Base.configurations.configs_for(
      env_name: "test",
      name: "primary"
    )

    assert_not test_database.seeds?
  end
end
