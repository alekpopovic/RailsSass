require "test_helper"
require "json"
require "open3"

class ProductionSecurityConfigurationTest < ActiveSupport::TestCase
  PRODUCTION_CONFIGURATION = <<~'RUBY'.freeze
    require "json"

    configuration = Rails.application.config
    puts JSON.generate(
      assume_ssl: configuration.assume_ssl,
      force_ssl: configuration.force_ssl,
      hosts: configuration.hosts.map(&:to_s),
      consider_all_requests_local: configuration.consider_all_requests_local,
      mailer_url_options: configuration.action_mailer.default_url_options,
      session_options: configuration.session_options.slice(:key, :httponly, :same_site, :secure),
      hsts: configuration.ssl_options.fetch(:hsts),
      default_headers: configuration.action_dispatch.default_headers
    )
  RUBY

  test "production boots only with one canonical host and enforces TLS and secure cookies" do
    stdout, stderr, status = production_runner(APP_HOST: "app.example.test")

    assert status.success?, "production boot failed: #{stderr}"
    configuration = JSON.parse(stdout.lines.last)
    assert_equal true, configuration.fetch("assume_ssl")
    assert_equal true, configuration.fetch("force_ssl")
    assert_equal [ "app.example.test" ], configuration.fetch("hosts")
    assert_equal false, configuration.fetch("consider_all_requests_local")
    assert_equal({ "host" => "app.example.test", "protocol" => "https" },
      configuration.fetch("mailer_url_options"))
    assert_equal(
      {
        "key" => "_rails_sass_session",
        "httponly" => true,
        "same_site" => "lax",
        "secure" => true
      },
      configuration.fetch("session_options")
    )
    assert_equal 1.year.to_i, configuration.dig("hsts", "expires").to_i
    assert_equal true, configuration.dig("hsts", "subdomains")
    assert_equal false, configuration.dig("hsts", "preload")
    assert_equal "DENY", configuration.dig("default_headers", "X-Frame-Options")
  end

  test "production rejects a missing or URL-shaped APP_HOST" do
    [ nil, "https://app.example.test/path" ].each do |host|
      _stdout, stderr, status = production_runner(APP_HOST: host)

      assert_not status.success?
      assert_includes stderr, "APP_HOST"
    end
  end

  private
    def production_runner(environment)
      Open3.capture3(
        {
          "RAILS_ENV" => "production",
          "SECRET_KEY_BASE_DUMMY" => "1",
          "LEMON_SQUEEZY_ENVIRONMENT" => "live",
          "APP_HOST" => environment.fetch(:APP_HOST)
        },
        Rails.root.join("bin/rails").to_s,
        "runner",
        PRODUCTION_CONFIGURATION
      )
    end
end
