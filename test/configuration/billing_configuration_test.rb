require "test_helper"

class BillingConfigurationTest < ActiveSupport::TestCase
  test "credentials-only checkout selection is shared by pricing configuration and the client" do
    original_environment = ENV.delete("LEMON_SQUEEZY_ENVIRONMENT")
    original_store_id = ENV.delete("LEMON_SQUEEZY_STORE_ID")
    original_webhook_secret = ENV.delete("LEMON_SQUEEZY_WEBHOOK_SECRET")
    original_configured_environment = Rails.configuration.x.billing.lemon_squeezy.environment
    original_configured_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    original_configured_webhook_secret = Rails.configuration.x.billing.lemon_squeezy.webhook_secret
    credentials = {
      lemon_squeezy: {
        environment: "live",
        store_id: "456",
        webhook_secret: "synthetic-credential-secret"
      }
    }
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
    assert_equal "synthetic-credential-secret",
      Rails.configuration.x.billing.lemon_squeezy.webhook_secret
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
    if original_webhook_secret
      ENV["LEMON_SQUEEZY_WEBHOOK_SECRET"] = original_webhook_secret
    else
      ENV.delete("LEMON_SQUEEZY_WEBHOOK_SECRET")
    end
    Rails.configuration.x.billing.lemon_squeezy.environment = original_configured_environment
    Rails.configuration.x.billing.lemon_squeezy.store_id = original_configured_store_id
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = original_configured_webhook_secret
    Rails.application.define_singleton_method(:credentials, original_credentials_method)
  end
end
