require "test_helper"

class BillingConfigurationTest < ActiveSupport::TestCase
  test "credentials-only checkout selection is shared by pricing configuration and the client" do
    original_environment = ENV.delete("LEMON_SQUEEZY_ENVIRONMENT")
    original_store_id = ENV.delete("LEMON_SQUEEZY_STORE_ID")
    original_configured_environment = Rails.configuration.x.billing.lemon_squeezy.environment
    original_configured_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    credentials = { lemon_squeezy: { environment: "live", store_id: "456" } }
    original_credentials_method = Rails.application.method(:credentials)
    Rails.application.define_singleton_method(:credentials) { credentials }

    load Rails.root.join("config/initializers/billing.rb")
    client = Billing::LemonSqueezy::Client.new(
      api_key: "synthetic-configuration-key",
      checkout_host: "checkout.example.test",
      env: {},
      credentials: {}
    )

    assert_equal "live", Rails.configuration.x.billing.lemon_squeezy.environment
    assert_equal Rails.configuration.x.billing.lemon_squeezy.environment, client.environment
    assert_equal "456", Rails.configuration.x.billing.lemon_squeezy.store_id
    assert_equal Rails.configuration.x.billing.lemon_squeezy.store_id, client.store_id
  ensure
    if original_environment
      ENV["LEMON_SQUEEZY_ENVIRONMENT"] = original_environment
    else
      ENV.delete("LEMON_SQUEEZY_ENVIRONMENT")
    end
    if original_store_id
      ENV["LEMON_SQUEEZY_STORE_ID"] = original_store_id
    else
      ENV.delete("LEMON_SQUEEZY_STORE_ID")
    end
    Rails.configuration.x.billing.lemon_squeezy.environment = original_configured_environment
    Rails.configuration.x.billing.lemon_squeezy.store_id = original_configured_store_id
    Rails.application.define_singleton_method(:credentials, original_credentials_method)
  end
end
