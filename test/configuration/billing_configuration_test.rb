require "test_helper"
require "json"
require "open3"

class BillingConfigurationTest < ActiveSupport::TestCase
  CURRENT_SECRET = "synthetic-current-webhook-secret"
  PREVIOUS_SECRET = "synthetic-previous-webhook-secret"
  FUTURE_EXPIRY = (Time.now.utc + 1.day).change(usec: 0).iso8601
  EXCESSIVE_EXPIRY = (Time.now.utc + 8.days).change(usec: 0).iso8601
  ROTATION_CONFIGURATION = <<~'RUBY'.freeze
    require "json"

    configuration = Rails.configuration.x.billing.lemon_squeezy
    puts JSON.generate(
      previous_secret_configured: configuration.webhook_previous_secret.present?,
      previous_secret_expires_at: configuration.webhook_previous_secret_expires_at&.iso8601
    )
  RUBY

  test "credentials-only checkout selection is shared by pricing configuration and the client" do
    environment_names = %w[
      LEMON_SQUEEZY_ENVIRONMENT
      LEMON_SQUEEZY_STORE_ID
      LEMON_SQUEEZY_WEBHOOK_SECRET
      LEMON_SQUEEZY_WEBHOOK_PREVIOUS_SECRET
      LEMON_SQUEEZY_WEBHOOK_PREVIOUS_SECRET_EXPIRES_AT
    ]
    original_environment = environment_names.to_h { |name| [ name, ENV.delete(name) ] }
    original_configured_environment = Rails.configuration.x.billing.lemon_squeezy.environment
    original_configured_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    original_configured_webhook_secret = Rails.configuration.x.billing.lemon_squeezy.webhook_secret
    original_configured_webhook_previous_secret =
      Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret
    original_configured_webhook_previous_secret_expires_at =
      Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at
    previous_secret_expires_at = 2.days.from_now.utc.change(usec: 0)
    credentials = {
      lemon_squeezy: {
        environment: "live",
        store_id: "456",
        webhook_secret: "synthetic-credential-secret",
        webhook_previous_secret: "synthetic-previous-credential-secret",
        webhook_previous_secret_expires_at: previous_secret_expires_at.iso8601
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
    assert_equal "synthetic-previous-credential-secret",
      Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret
    assert_equal previous_secret_expires_at,
      Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at
  ensure
    restore_environment(original_environment) if original_environment
    Rails.configuration.x.billing.lemon_squeezy.environment = original_configured_environment
    Rails.configuration.x.billing.lemon_squeezy.store_id = original_configured_store_id
    Rails.configuration.x.billing.lemon_squeezy.webhook_secret = original_configured_webhook_secret
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret =
      original_configured_webhook_previous_secret
    Rails.configuration.x.billing.lemon_squeezy.webhook_previous_secret_expires_at =
      original_configured_webhook_previous_secret_expires_at
    Rails.application.define_singleton_method(:credentials, original_credentials_method)
  end

  test "production accepts a complete bounded previous-secret configuration" do
    stdout, stderr, status = production_rotation_runner(
      previous_secret: PREVIOUS_SECRET,
      expires_at: FUTURE_EXPIRY
    )

    assert status.success?, "production boot failed: #{stderr}"
    assert_equal 7.days, LemonSqueezyWebhookRotation::MAX_PREVIOUS_SECRET_OVERLAP
    configuration = JSON.parse(stdout.lines.last)
    assert_equal true, configuration.fetch("previous_secret_configured")
    assert_equal FUTURE_EXPIRY, configuration.fetch("previous_secret_expires_at")
  end

  test "production rejects partial stale non-UTC and duplicate rotation configuration" do
    invalid_configurations = {
      "missing expiry" => { previous_secret: PREVIOUS_SECRET, expires_at: nil },
      "missing previous secret" => { previous_secret: nil, expires_at: FUTURE_EXPIRY },
      "non-Z UTC offset" => {
        previous_secret: PREVIOUS_SECRET,
        expires_at: "2099-01-02T03:04:05+00:00"
      },
      "expired instant" => {
        previous_secret: PREVIOUS_SECRET,
        expires_at: "2000-01-02T03:04:05Z"
      },
      "overlap beyond seven days" => {
        previous_secret: PREVIOUS_SECRET,
        expires_at: EXCESSIVE_EXPIRY
      },
      "duplicate secret" => { previous_secret: CURRENT_SECRET, expires_at: FUTURE_EXPIRY }
    }

    invalid_configurations.each do |name, configuration|
      _stdout, stderr, status = production_rotation_runner(**configuration)

      assert_not status.success?, "#{name} unexpectedly allowed production to boot"
      assert_includes stderr, "webhook secret rotation configuration is invalid"
    end
  end

  private
    def restore_environment(environment)
      environment.each do |name, value|
        value ? ENV[name] = value : ENV.delete(name)
      end
    end

    def production_rotation_runner(previous_secret:, expires_at:)
      Open3.capture3(
        {
          "RAILS_ENV" => "production",
          "SECRET_KEY_BASE_DUMMY" => "1",
          "APP_HOST" => "app.example.test",
          "LEMON_SQUEEZY_ENVIRONMENT" => "live",
          "LEMON_SQUEEZY_WEBHOOK_SECRET" => CURRENT_SECRET,
          "LEMON_SQUEEZY_WEBHOOK_PREVIOUS_SECRET" => previous_secret,
          "LEMON_SQUEEZY_WEBHOOK_PREVIOUS_SECRET_EXPIRES_AT" => expires_at
        },
        Rails.root.join("bin/rails").to_s,
        "runner",
        ROTATION_CONFIGURATION
      )
    end
end
