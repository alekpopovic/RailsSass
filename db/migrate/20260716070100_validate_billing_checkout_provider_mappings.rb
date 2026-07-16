class ValidateBillingCheckoutProviderMappings < ActiveRecord::Migration[8.1]
  FOREIGN_KEY_NAME = "fk_billing_checkout_attempts_provider_mapping"

  def up
    reject_invalid_legacy_identities!
    backfill_legacy_mappings
    validate_foreign_key :billing_checkout_attempts,
      :billing_provider_price_mappings,
      name: FOREIGN_KEY_NAME
  end

  def down
    remove_foreign_key :billing_checkout_attempts, name: FOREIGN_KEY_NAME
    add_foreign_key :billing_checkout_attempts,
      :billing_provider_price_mappings,
      column: [ :plan_price_id, :provider, :environment ],
      primary_key: [ :plan_price_id, :provider, :environment ],
      on_delete: :restrict,
      validate: false,
      name: FOREIGN_KEY_NAME
  end

  private
    def reject_invalid_legacy_identities!
      invalid_count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM billing_checkout_attempts attempts
        INNER JOIN plan_prices prices ON prices.id = attempts.plan_price_id
        LEFT JOIN billing_provider_price_mappings mappings
          ON mappings.plan_price_id = attempts.plan_price_id
          AND mappings.provider = attempts.provider
          AND mappings.environment = attempts.environment
        WHERE mappings.id IS NULL
          AND (
            prices.lemon_store_id IS NULL
            OR prices.lemon_product_id IS NULL
            OR prices.lemon_variant_id IS NULL
            OR prices.lemon_store_id !~ '^[1-9][0-9]*$'
            OR prices.lemon_product_id !~ '^[1-9][0-9]*$'
            OR prices.lemon_variant_id !~ '^[1-9][0-9]*$'
          )
      SQL
      return if invalid_count.zero?

      raise ActiveRecord::MigrationError,
        "#{invalid_count} legacy checkout attempt price mapping(s) require remediation"
    end

    def backfill_legacy_mappings
      execute <<~SQL
        INSERT INTO billing_provider_price_mappings (
          plan_price_id,
          provider,
          environment,
          provider_store_id,
          provider_product_id,
          provider_variant_id,
          active,
          created_at,
          updated_at
        )
        SELECT DISTINCT
          attempts.plan_price_id,
          attempts.provider,
          attempts.environment,
          prices.lemon_store_id,
          prices.lemon_product_id,
          prices.lemon_variant_id,
          FALSE,
          CURRENT_TIMESTAMP,
          CURRENT_TIMESTAMP
        FROM billing_checkout_attempts attempts
        INNER JOIN plan_prices prices ON prices.id = attempts.plan_price_id
        LEFT JOIN billing_provider_price_mappings mappings
          ON mappings.plan_price_id = attempts.plan_price_id
          AND mappings.provider = attempts.provider
          AND mappings.environment = attempts.environment
        WHERE mappings.id IS NULL
        ON CONFLICT (plan_price_id, provider, environment) DO NOTHING
      SQL
    end
end
