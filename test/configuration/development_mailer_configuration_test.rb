require "test_helper"
require "json"
require "open3"
require "yaml"

class DevelopmentMailerConfigurationTest < ActiveSupport::TestCase
  test "development sends mail through the configured local SMTP catcher" do
    environment = {
      "APP_HOST" => "app.example.test",
      "APP_PORT" => "3100",
      "DATABASE_URL" => "postgresql://unused:unused@127.0.0.1:1/unused",
      "RAILS_ENV" => "development",
      "SMTP_ADDRESS" => "smtp.example.test",
      "SMTP_PORT" => "2526"
    }
    script = <<~'RUBY'
      require "json"

      mailer = Rails.application.config.action_mailer
      puts "MAILER_CONFIG=#{JSON.generate(
        active_job_adapter: ActiveJob::Base.queue_adapter.class.name,
        delivery_method: mailer.delivery_method,
        perform_deliveries: mailer.perform_deliveries,
        raise_delivery_errors: mailer.raise_delivery_errors,
        smtp_settings: mailer.smtp_settings,
        default_url_options: mailer.default_url_options
      )}"
    RUBY

    stdout, stderr, status = Open3.capture3(
      environment,
      Rails.root.join("bin/rails").to_s,
      "runner",
      script,
      chdir: Rails.root.to_s
    )

    assert status.success?, stderr
    payload = JSON.parse(stdout.lines.grep(/^MAILER_CONFIG=/).sole.delete_prefix("MAILER_CONFIG="))

    assert_equal "ActiveJob::QueueAdapters::AsyncAdapter", payload.fetch("active_job_adapter")
    assert_equal "smtp", payload.fetch("delivery_method")
    assert payload.fetch("perform_deliveries")
    assert payload.fetch("raise_delivery_errors")
    assert_equal(
      {
        "address" => "smtp.example.test",
        "port" => 2526,
        "authentication" => nil,
        "enable_starttls_auto" => false
      },
      payload.fetch("smtp_settings")
    )
    assert_equal(
      { "host" => "app.example.test", "port" => 3100, "protocol" => "http" },
      payload.fetch("default_url_options")
    )
  end

  test "Compose provides a private healthchecked MailCatcher to host and container Rails" do
    services = YAML.safe_load(Rails.root.join("compose.yaml").read, aliases: true).fetch("services")
    mailcatcher = services.fetch("mailcatcher")
    app = services.fetch("app")

    assert_equal(
      "sj26/mailcatcher:v0.10.0@sha256:5d153a4daadf0c266f29c3856085741f06ca1e3768671f4267622d3e3ffe5564",
      mailcatcher.fetch("image")
    )
    assert_equal [
      "127.0.0.1:${SMTP_PORT:-1025}:1025",
      "127.0.0.1:${MAILCATCHER_HTTP_PORT:-1080}:1080"
    ], mailcatcher.fetch("ports")
    assert_includes mailcatcher.fetch("command"), "--no-quit"
    assert_equal "http://127.0.0.1:1080/", mailcatcher.dig("healthcheck", "test").last
    assert_equal "service_healthy", app.dig("depends_on", "mailcatcher", "condition")
    assert_equal "mailcatcher", app.dig("environment", "SMTP_ADDRESS")
    assert_equal 1025, app.dig("environment", "SMTP_PORT")
  end

  test "test mail delivery remains isolated from development SMTP" do
    assert_equal :test, Rails.application.config.action_mailer.delivery_method
  end
end
