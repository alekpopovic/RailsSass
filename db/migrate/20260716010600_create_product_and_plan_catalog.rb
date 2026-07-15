class CreateProductAndPlanCatalog < ActiveRecord::Migration[8.1]
  def change
    create_products
    create_product_features
    create_plans
    create_plan_products
    create_plan_feature_entitlements
    create_plan_prices
  end

  private
    def create_products
      create_table :products do |t|
        t.string :key, null: false, limit: 63
        t.string :name, null: false, limit: 100
        t.text :description, null: false, default: ""
        t.boolean :active, null: false, default: true

        t.timestamps null: false
      end

      add_index :products, :key, unique: true
      add_index :products, :active

      add_catalog_identity_constraints(:products)
    end

    def create_product_features
      create_table :product_features do |t|
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :key, null: false, limit: 63
        t.string :name, null: false, limit: 100
        t.text :description, null: false, default: ""
        t.string :kind, null: false, limit: 16
        t.boolean :active, null: false, default: true

        t.timestamps null: false
      end

      add_index :product_features, [ :product_id, :key ], unique: true
      add_index :product_features, [ :id, :product_id, :kind ], unique: true,
        name: "index_product_features_on_id_product_and_kind"
      add_index :product_features, [ :product_id, :active ]

      add_catalog_identity_constraints(:product_features)
      add_check_constraint :product_features,
        "kind IN ('flag', 'limit')",
        name: "product_features_kind_allowed"
    end

    def create_plans
      create_table :plans do |t|
        t.string :key, null: false, limit: 63
        t.string :name, null: false, limit: 100
        t.text :description, null: false, default: ""
        t.boolean :active, null: false, default: true
        t.boolean :free, null: false, default: false
        t.integer :position, null: false, default: 0

        t.timestamps null: false
      end

      add_index :plans, :key, unique: true
      add_index :plans, [ :active, :position ]
      add_index :plans,
        :free,
        unique: true,
        where: "active AND free",
        name: "index_plans_on_single_active_free"

      add_catalog_identity_constraints(:plans)
      add_check_constraint :plans,
        "position >= 0",
        name: "plans_position_non_negative"
    end

    def create_plan_products
      create_table :plan_products do |t|
        t.references :plan,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }

        t.timestamps null: false
      end

      add_index :plan_products, [ :plan_id, :product_id ], unique: true
      add_index :plan_products, [ :id, :product_id ], unique: true,
        name: "index_plan_products_on_id_and_product_id"
    end

    def create_plan_feature_entitlements
      create_table :plan_feature_entitlements do |t|
        t.references :plan_product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :product_feature,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :feature_kind, null: false, limit: 16
        t.boolean :enabled, null: false, default: false
        t.bigint :limit_value
        t.boolean :unlimited, null: false, default: false
        t.jsonb :settings, null: false, default: {}

        t.timestamps null: false
      end

      add_index :plan_feature_entitlements,
        [ :plan_product_id, :product_feature_id ],
        unique: true,
        name: "index_plan_feature_entitlements_on_product_and_feature"

      add_foreign_key :plan_feature_entitlements,
        :plan_products,
        column: [ :plan_product_id, :product_id ],
        primary_key: [ :id, :product_id ],
        on_delete: :restrict,
        name: "fk_plan_feature_entitlements_plan_product"
      add_foreign_key :plan_feature_entitlements,
        :product_features,
        column: [ :product_feature_id, :product_id, :feature_kind ],
        primary_key: [ :id, :product_id, :kind ],
        on_delete: :restrict,
        name: "fk_plan_feature_entitlements_product_feature"

      add_check_constraint :plan_feature_entitlements,
        "feature_kind IN ('flag', 'limit')",
        name: "plan_feature_entitlements_kind_allowed"
      add_check_constraint :plan_feature_entitlements,
        <<~SQL.squish,
          (
            feature_kind = 'flag'
            AND limit_value IS NULL
            AND unlimited = FALSE
          ) OR (
            feature_kind = 'limit'
            AND (
              (unlimited = TRUE AND limit_value IS NULL)
              OR
              (unlimited = FALSE AND limit_value IS NOT NULL AND limit_value >= 0)
            )
          )
        SQL
        name: "plan_feature_entitlements_typed_value"
      add_check_constraint :plan_feature_entitlements,
        "jsonb_typeof(settings) = 'object'",
        name: "plan_feature_entitlements_settings_object"
    end

    def create_plan_prices
      create_table :plan_prices do |t|
        t.references :plan,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :billing_interval, null: false, limit: 16
        t.string :currency, null: false, limit: 3
        t.bigint :amount_cents, null: false
        t.string :lemon_store_id, limit: 64
        t.string :lemon_product_id, limit: 64
        t.string :lemon_variant_id, limit: 64
        t.boolean :active, null: false, default: true

        t.timestamps null: false
      end

      add_index :plan_prices, [ :plan_id, :active, :billing_interval, :currency ],
        name: "index_plan_prices_on_plan_and_selection"
      add_index :plan_prices,
        :lemon_variant_id,
        unique: true,
        where: "lemon_variant_id IS NOT NULL"

      add_check_constraint :plan_prices,
        "billing_interval IN ('monthly', 'yearly')",
        name: "plan_prices_billing_interval_allowed"
      add_check_constraint :plan_prices,
        "currency ~ '^[A-Z]{3}$'",
        name: "plan_prices_currency_format"
      add_check_constraint :plan_prices,
        "amount_cents >= 0",
        name: "plan_prices_amount_non_negative"
      add_check_constraint :plan_prices,
        <<~SQL.squish,
          (
            lemon_store_id IS NULL
            AND lemon_product_id IS NULL
            AND lemon_variant_id IS NULL
          ) OR (
            lemon_store_id IS NOT NULL
            AND lemon_store_id = btrim(lemon_store_id)
            AND lemon_store_id !~ '[[:space:]]'
            AND char_length(lemon_store_id) BETWEEN 1 AND 64
            AND lemon_product_id IS NOT NULL
            AND lemon_product_id = btrim(lemon_product_id)
            AND lemon_product_id !~ '[[:space:]]'
            AND char_length(lemon_product_id) BETWEEN 1 AND 64
            AND lemon_variant_id IS NOT NULL
            AND lemon_variant_id = btrim(lemon_variant_id)
            AND lemon_variant_id !~ '[[:space:]]'
            AND char_length(lemon_variant_id) BETWEEN 1 AND 64
          )
        SQL
        name: "plan_prices_lemon_mapping_complete"
    end

    def add_catalog_identity_constraints(table_name)
      add_check_constraint table_name,
        "key ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$' AND " \
          "char_length(key) BETWEEN 1 AND 63",
        name: "#{table_name}_key_format"
      add_check_constraint table_name,
        "name = btrim(name) AND char_length(name) BETWEEN 1 AND 100",
        name: "#{table_name}_name_normalized"
      add_check_constraint table_name,
        "description = btrim(description) AND char_length(description) <= 2000",
        name: "#{table_name}_description_normalized"
    end
end
