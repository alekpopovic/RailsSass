require "test_helper"

class EntitlementsConfigurationTest < ActiveSupport::TestCase
  test "uses the configured non-secret past-due grace period" do
    configured_days = Integer(ENV.fetch("ENTITLEMENTS_PAST_DUE_GRACE_DAYS", "15"), 10)

    assert_equal configured_days.days,
      Rails.application.config.x.entitlements.past_due_grace_period
  end
end
