class CreateBillingCheckoutMappingAndLocators < ActiveRecord::Migration[8.1]
  def change
    add_plan_price_mapping_identity
    create_provider_price_mappings
    bind_checkout_attempts_to_provider_mapping
    create_provider_locators
  end

  private
    def add_plan_price_mapping_identity
      add_index :plan_prices,
        [ :id, :lemon_store_id, :lemon_product_id, :lemon_variant_id ],
        unique: true,
        name: "index_plan_prices_on_provider_mapping_identity"
    end

    def create_provider_price_mappings
      create_table :billing_provider_price_mappings do |t|
        t.references :plan_price,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.string :provider_store_id, null: false, limit: 64
        t.string :provider_product_id, null: false, limit: 64
        t.string :provider_variant_id, null: false, limit: 64
        t.boolean :active, null: false, default: true

        t.timestamps null: false
      end

      add_index :billing_provider_price_mappings,
        [ :plan_price_id, :provider, :environment ],
        unique: true,
        name: "index_billing_price_mappings_on_local_identity"
      add_index :billing_provider_price_mappings,
        [ :provider, :environment, :provider_store_id, :provider_product_id, :provider_variant_id ],
        unique: true,
        name: "index_billing_price_mappings_on_provider_identity"
      add_index :billing_provider_price_mappings,
        [ :provider, :environment, :provider_store_id, :provider_variant_id ],
        name: "index_billing_price_mappings_on_provider_lookup"

      add_foreign_key :billing_provider_price_mappings,
        :plan_prices,
        column: [
          :plan_price_id,
          :provider_store_id,
          :provider_product_id,
          :provider_variant_id
        ],
        primary_key: [
          :id,
          :lemon_store_id,
          :lemon_product_id,
          :lemon_variant_id
        ],
        on_delete: :restrict,
        name: "fk_billing_price_mappings_plan_price_identity"

      add_check_constraint :billing_provider_price_mappings,
        "provider = 'lemon_squeezy'",
        name: "billing_price_mappings_provider_allowed"
      add_check_constraint :billing_provider_price_mappings,
        "environment IN ('test', 'live')",
        name: "billing_price_mappings_environment_allowed"
      %i[provider_store_id provider_product_id provider_variant_id].each do |column|
        add_check_constraint :billing_provider_price_mappings,
          "#{column} = btrim(#{column}) AND " \
            "#{column} ~ '^[1-9][0-9]*$' AND " \
            "char_length(#{column}) BETWEEN 1 AND 64",
          name: "billing_price_mappings_#{column.to_s.delete_prefix('provider_')}_normalized"
      end
    end

    def bind_checkout_attempts_to_provider_mapping
      add_foreign_key :billing_checkout_attempts,
        :billing_provider_price_mappings,
        column: [ :plan_price_id, :provider, :environment ],
        primary_key: [ :plan_price_id, :provider, :environment ],
        on_delete: :restrict,
        validate: false,
        name: "fk_billing_checkout_attempts_provider_mapping"
    end

    def create_provider_locators
      create_table :billing_provider_locators do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.bigint :billing_checkout_attempt_id, null: false
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.string :token_digest, null: false, limit: 64
        t.string :status, null: false, default: "unresolved", limit: 32
        t.datetime :resolved_at

        t.timestamps null: false
      end

      add_index :billing_provider_locators,
        :billing_checkout_attempt_id,
        unique: true,
        name: "index_billing_provider_locators_on_checkout_attempt"
      add_index :billing_provider_locators,
        [ :provider, :environment, :token_digest ],
        unique: true,
        name: "index_billing_provider_locators_on_token_identity"
      add_index :billing_provider_locators,
        [ :organization_id, :status ],
        name: "index_billing_provider_locators_on_org_status"

      add_foreign_key :billing_provider_locators,
        :billing_checkout_attempts,
        column: [
          :billing_checkout_attempt_id,
          :organization_id,
          :provider,
          :environment,
          :token_digest
        ],
        primary_key: [
          :id,
          :organization_id,
          :provider,
          :environment,
          :token_digest
        ],
        on_delete: :restrict,
        name: "fk_billing_provider_locators_checkout_identity"

      add_check_constraint :billing_provider_locators,
        "provider = 'lemon_squeezy'",
        name: "billing_provider_locators_provider_allowed"
      add_check_constraint :billing_provider_locators,
        "environment IN ('test', 'live')",
        name: "billing_provider_locators_environment_allowed"
      add_check_constraint :billing_provider_locators,
        "token_digest ~ '^[0-9a-f]{64}$'",
        name: "billing_provider_locators_token_digest_format"
      add_check_constraint :billing_provider_locators,
        <<~SQL.squish,
          (
            status = 'unresolved'
            AND resolved_at IS NULL
          ) OR (
            status IN ('consumed', 'definitive_creation_failure')
            AND resolved_at IS NOT NULL
          )
        SQL
        name: "billing_provider_locators_lifecycle"
    end
end
