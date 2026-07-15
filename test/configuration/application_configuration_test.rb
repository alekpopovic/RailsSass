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
end
