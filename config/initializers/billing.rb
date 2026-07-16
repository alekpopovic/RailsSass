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

unless configured_lemon_environment.in?(%w[test live])
  raise ArgumentError, "LEMON_SQUEEZY_ENVIRONMENT must be test or live"
end

Rails.application.config.x.billing.lemon_squeezy = ActiveSupport::OrderedOptions.new
Rails.application.config.x.billing.lemon_squeezy.environment = configured_lemon_environment
Rails.application.config.x.billing.lemon_squeezy.store_id = configured_lemon_store_id
Rails.application.config.x.billing.lemon_squeezy.webhook_secret = configured_lemon_webhook_secret
