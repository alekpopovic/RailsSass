require "time"

module LemonSqueezyWebhookRotation
  MAX_PREVIOUS_SECRET_OVERLAP = 7.days unless const_defined?(:MAX_PREVIOUS_SECRET_OVERLAP, false)
end

credential_lemon_environment = Rails.application.credentials.dig(
  :lemon_squeezy,
  :environment
) || Rails.application.credentials.dig("lemon_squeezy", "environment")
credential_lemon_store_id = Rails.application.credentials.dig(
  :lemon_squeezy,
  :store_id
) || Rails.application.credentials.dig("lemon_squeezy", "store_id")
credential_lemon_webhook_secret = Rails.application.credentials.dig(
  :lemon_squeezy,
  :webhook_secret
) || Rails.application.credentials.dig("lemon_squeezy", "webhook_secret")
credential_lemon_webhook_previous_secret = Rails.application.credentials.dig(
  :lemon_squeezy,
  :webhook_previous_secret
) || Rails.application.credentials.dig("lemon_squeezy", "webhook_previous_secret")
credential_lemon_webhook_previous_secret_expires_at = Rails.application.credentials.dig(
  :lemon_squeezy,
  :webhook_previous_secret_expires_at
) || Rails.application.credentials.dig("lemon_squeezy", "webhook_previous_secret_expires_at")
configured_lemon_environment = [
  ENV["LEMON_SQUEEZY_ENVIRONMENT"],
  credential_lemon_environment,
  Rails.env.production? ? "live" : "test"
].filter_map { |value| value.to_s.strip.presence }.first
configured_lemon_store_id = [
  ENV["LEMON_SQUEEZY_STORE_ID"],
  credential_lemon_store_id
].filter_map { |value| value.to_s.strip.presence }.first
configured_lemon_webhook_secret = [
  ENV["LEMON_SQUEEZY_WEBHOOK_SECRET"],
  credential_lemon_webhook_secret
].filter_map { |value| value.to_s.presence }.first
configured_lemon_webhook_previous_secret = [
  ENV["LEMON_SQUEEZY_WEBHOOK_PREVIOUS_SECRET"],
  credential_lemon_webhook_previous_secret
].filter_map { |value| value.to_s.presence }.first
configured_lemon_webhook_previous_secret_expires_at_value = [
  ENV["LEMON_SQUEEZY_WEBHOOK_PREVIOUS_SECRET_EXPIRES_AT"],
  credential_lemon_webhook_previous_secret_expires_at
].filter_map { |value| value.to_s.strip.presence }.first

unless configured_lemon_environment.in?(%w[test live])
  raise ArgumentError, "LEMON_SQUEEZY_ENVIRONMENT must be test or live"
end

strict_utc_instant_pattern = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z/
configured_lemon_webhook_previous_secret_expires_at = begin
  value = configured_lemon_webhook_previous_secret_expires_at_value
  Time.iso8601(value) if strict_utc_instant_pattern.match?(value.to_s)
rescue ArgumentError
  nil
end

previous_secret_present = configured_lemon_webhook_previous_secret.present?
previous_expiry_present = configured_lemon_webhook_previous_secret_expires_at_value.present?
webhook_rotation_configuration_time = Time.current
previous_rotation_error = if previous_secret_present != previous_expiry_present
  "previous secret and expiry must be configured together"
elsif previous_secret_present && configured_lemon_webhook_secret.blank?
  "current secret is required when a previous secret is configured"
elsif previous_secret_present && configured_lemon_webhook_previous_secret_expires_at.nil?
  "previous secret expiry must be a strict ISO8601 UTC instant"
elsif previous_secret_present &&
    configured_lemon_webhook_previous_secret_expires_at <= webhook_rotation_configuration_time
  "previous secret expiry must be in the future"
elsif previous_secret_present && configured_lemon_webhook_previous_secret_expires_at >
    webhook_rotation_configuration_time + LemonSqueezyWebhookRotation::MAX_PREVIOUS_SECRET_OVERLAP
  "previous secret expiry cannot exceed seven days from boot"
elsif previous_secret_present &&
    configured_lemon_webhook_previous_secret == configured_lemon_webhook_secret
  "current and previous secrets must differ"
end

if previous_rotation_error
  if Rails.env.production?
    raise ArgumentError,
      "Lemon Squeezy webhook secret rotation configuration is invalid: #{previous_rotation_error}"
  end

  configured_lemon_webhook_previous_secret = nil
  configured_lemon_webhook_previous_secret_expires_at = nil
end

Rails.application.config.x.billing.lemon_squeezy = ActiveSupport::OrderedOptions.new
Rails.application.config.x.billing.lemon_squeezy.environment = configured_lemon_environment
Rails.application.config.x.billing.lemon_squeezy.store_id = configured_lemon_store_id
Rails.application.config.x.billing.lemon_squeezy.webhook_secret = configured_lemon_webhook_secret
Rails.application.config.x.billing.lemon_squeezy.webhook_previous_secret =
  configured_lemon_webhook_previous_secret
Rails.application.config.x.billing.lemon_squeezy.webhook_previous_secret_expires_at =
  configured_lemon_webhook_previous_secret_expires_at
