require "test_helper"
require_relative "../support/catalog_test_helper"

class CreateProductAndPlanCatalogTest < ActiveSupport::TestCase
  include CatalogTestHelper

  test "catalog columns, checks, and uniqueness indexes are installed" do
    assert_required_columns(Product, %w[key name description active created_at updated_at])
    assert_required_columns(ProductFeature, %w[product_id key name description kind active created_at updated_at])
    assert_required_columns(Plan, %w[key name description active free position created_at updated_at])
    assert_required_columns(PlanProduct, %w[plan_id product_id created_at updated_at])
    assert_required_columns(
      PlanFeatureEntitlement,
      %w[plan_product_id product_feature_id product_id feature_kind enabled unlimited settings created_at updated_at]
    )
    assert_required_columns(
      PlanPrice,
      %w[plan_id billing_interval currency amount_cents active created_at updated_at]
    )

    assert_constraint_names(Product, %w[products_key_format products_name_normalized products_description_normalized])
    assert_constraint_names(ProductFeature, %w[product_features_key_format product_features_kind_allowed])
    assert_constraint_names(Plan, %w[plans_key_format plans_position_non_negative])
    assert_constraint_names(
      PlanFeatureEntitlement,
      %w[
        plan_feature_entitlements_kind_allowed
        plan_feature_entitlements_typed_value
        plan_feature_entitlements_settings_object
      ]
    )
    assert_constraint_names(
      PlanPrice,
      %w[
        plan_prices_billing_interval_allowed
        plan_prices_currency_format
        plan_prices_amount_non_negative
        plan_prices_lemon_mapping_complete
      ]
    )

    assert_predicate index_for(Product, "index_products_on_key"), :unique
    assert_predicate index_for(ProductFeature, "index_product_features_on_product_id_and_key"), :unique
    assert_predicate index_for(PlanProduct, "index_plan_products_on_plan_id_and_product_id"), :unique
    assert_predicate index_for(
      PlanFeatureEntitlement,
      "index_plan_feature_entitlements_on_product_and_feature"
    ), :unique
    assert_predicate index_for(PlanPrice, "index_plan_prices_on_lemon_variant_id"), :unique
    assert_match(/lemon_variant_id IS NOT NULL/i, index_for(
      PlanPrice,
      "index_plan_prices_on_lemon_variant_id"
    ).where)
    assert_match(/active AND free/i, index_for(Plan, "index_plans_on_single_active_free").where)
  end

  test "entitlement composite foreign keys enforce product and feature kind consistency" do
    plan_product = create_test_plan_product(plan: create_test_plan, product: create_test_product)
    other_feature = create_test_product_feature(product: create_test_product, kind: :flag)

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: other_feature,
        product_id: plan_product.product_id,
        feature_kind: other_feature.kind
      ) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database enforces catalog key format and global product key uniqueness" do
    product = create_test_product(key: "stable_database_key")

    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      Product.insert_all!([ raw_product_attributes(key: "invalid__key") ])
    end
    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      Product.insert_all!([ raw_product_attributes(key: product.key) ])
    end
  end

  test "database enforces feature kind and per-product key uniqueness" do
    product = create_test_product
    feature = create_test_product_feature(product: product, key: "database_feature")

    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      ProductFeature.insert_all!([ raw_feature_attributes(
        product: product,
        key: unique_catalog_key("invalid_kind"),
        kind: "counter"
      ) ])
    end
    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      ProductFeature.insert_all!([ raw_feature_attributes(
        product: product,
        key: feature.key,
        kind: "flag"
      ) ])
    end
  end

  test "database enforces plan product and feature entitlement uniqueness" do
    product = create_test_product
    plan = create_test_plan
    plan_product = create_test_plan_product(plan: plan, product: product)
    feature = create_test_product_feature(product: product, kind: :flag)
    create_test_entitlement(plan_product: plan_product, product_feature: feature)

    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      PlanProduct.insert_all!([ raw_plan_product_attributes(plan: plan, product: product) ])
    end
    assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: feature
      ) ])
    end
  end

  test "catalog relationships use restricted ordinary and composite foreign keys" do
    models = [ ProductFeature, PlanProduct, PlanFeatureEntitlement, PlanPrice ]
    models.each do |model|
      assert model.connection.foreign_keys(model.table_name).all? { |foreign_key|
        foreign_key.on_delete == :restrict
      }, "expected every #{model.table_name} foreign key to restrict deletion"
    end

    entitlement_foreign_keys = PlanFeatureEntitlement.connection
      .foreign_keys(:plan_feature_entitlements)
    assert entitlement_foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "plan_products" &&
        foreign_key.column == %w[plan_product_id product_id] &&
        foreign_key.primary_key == %w[id product_id]
    }
    assert entitlement_foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "product_features" &&
        foreign_key.column == %w[product_feature_id product_id feature_kind] &&
        foreign_key.primary_key == %w[id product_id kind]
    }
  end

  test "catalog records are global metadata and do not create tenant grants" do
    catalog_models = [ Product, ProductFeature, Plan, PlanProduct, PlanFeatureEntitlement, PlanPrice ]
    catalog_models.each do |model|
      assert_not_includes model.column_names, "organization_id"
    end

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      plan = create_test_plan(active: true, free: false)
      create_test_plan_price(plan: plan, active: true)
    end
  end

  test "database rejects feature kind drift and malformed typed values" do
    product = create_test_product
    plan_product = create_test_plan_product(plan: create_test_plan, product: product)
    feature = create_test_product_feature(product: product, kind: :flag)

    kind_error = assert_raises(ActiveRecord::InvalidForeignKey) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: feature,
        feature_kind: "limit",
        limit_value: 1
      ) ])
    end
    assert_kind_of PG::ForeignKeyViolation, kind_error.cause
  end

  test "database rejects invalid typed values" do
    product = create_test_product
    plan_product = create_test_plan_product(plan: create_test_plan, product: product)
    feature = create_test_product_feature(product: product, kind: :flag)

    typed_error = assert_raises(ActiveRecord::StatementInvalid) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: feature,
        limit_value: 1
      ) ])
    end
    assert_kind_of PG::CheckViolation, typed_error.cause
  end

  test "database rejects missing and conflicting limit capacities" do
    product = create_test_product
    plan_product = create_test_plan_product(plan: create_test_plan, product: product)
    feature = create_test_product_feature(product: product, kind: :limit)

    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: feature
      ) ])
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: feature,
        limit_value: 10,
        unlimited: true
      ) ])
    end
  end

  test "database rejects non-object entitlement settings" do
    product = create_test_product
    plan_product = create_test_plan_product(plan: create_test_plan, product: product)
    feature = create_test_product_feature(product: product, kind: :flag)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      PlanFeatureEntitlement.insert_all!([ raw_entitlement_attributes(
        plan_product: plan_product,
        product_feature: feature,
        settings: [ "not", "an", "object" ]
      ) ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects an incomplete Lemon mapping" do
    now = Time.current
    error = assert_raises(ActiveRecord::StatementInvalid) do
      PlanPrice.insert_all!([ {
        plan_id: create_test_plan.id,
        billing_interval: "monthly",
        currency: "EUR",
        amount_cents: 1_000,
        lemon_store_id: "store-only",
        lemon_product_id: nil,
        lemon_variant_id: nil,
        active: true,
        created_at: now,
        updated_at: now
      } ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects invalid price interval currency amount and identifier whitespace" do
    plan = create_test_plan

    {
      billing_interval: "weekly",
      currency: "EU1",
      amount_cents: -1
    }.each do |attribute, value|
      assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
        PlanPrice.insert_all!([ raw_unmapped_price_attributes(plan: plan, **{ attribute => value }) ])
      end
    end
    assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      PlanPrice.insert_all!([ raw_price_attributes(
        plan: plan,
        lemon_variant_id: "variant-with-whitespace",
        lemon_store_id: "store\tidentifier"
      ) ])
    end
  end

  test "database enforces non-null Lemon variant uniqueness" do
    first_plan = create_test_plan
    second_plan = create_test_plan
    create_test_plan_price(
      plan: first_plan,
      lemon_store_id: "store-one",
      lemon_product_id: "product-one",
      lemon_variant_id: "variant-unique"
    )

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      PlanPrice.insert_all!([ raw_price_attributes(
        plan: second_plan,
        lemon_variant_id: "variant-unique"
      ) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database permits only one active free plan" do
    Plan.find_by(active: true, free: true) || create_test_plan(active: true, free: true)

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      Plan.insert_all!([ raw_plan_attributes(key: unique_catalog_key("other_free")) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  private
    def assert_required_columns(model, column_names)
      columns = model.columns.index_by(&:name)
      column_names.each do |column_name|
        assert_not columns.fetch(column_name).null, "expected #{model.table_name}.#{column_name} to be NOT NULL"
      end
    end

    def assert_database_error(exception_class, cause_class, &block)
      error = assert_raises(exception_class) do
        ApplicationRecord.transaction(requires_new: true, &block)
      end
      assert_kind_of cause_class, error.cause
    end

    def assert_constraint_names(model, expected_names)
      names = model.connection.check_constraints(model.table_name).map(&:name)
      expected_names.each { |name| assert_includes names, name }
    end

    def index_for(model, name)
      model.connection.indexes(model.table_name).index_by(&:name).fetch(name)
    end

    def raw_entitlement_attributes(plan_product:, product_feature:, **overrides)
      now = Time.current
      {
        plan_product_id: plan_product.id,
        product_feature_id: product_feature.id,
        product_id: plan_product.product_id,
        feature_kind: product_feature.kind,
        enabled: true,
        limit_value: nil,
        unlimited: false,
        settings: {},
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def raw_product_attributes(key:)
      now = Time.current
      {
        key: key,
        name: "Raw Product",
        description: "Synthetic raw product.",
        active: true,
        created_at: now,
        updated_at: now
      }
    end

    def raw_feature_attributes(product:, key:, kind:)
      now = Time.current
      {
        product_id: product.id,
        key: key,
        name: "Raw Feature",
        description: "Synthetic raw feature.",
        kind: kind,
        active: true,
        created_at: now,
        updated_at: now
      }
    end

    def raw_plan_product_attributes(plan:, product:)
      now = Time.current
      {
        plan_id: plan.id,
        product_id: product.id,
        created_at: now,
        updated_at: now
      }
    end

    def raw_plan_attributes(key:)
      now = Time.current
      {
        key: key,
        name: "Concurrent Free Plan",
        description: "Synthetic free plan.",
        active: true,
        free: true,
        position: 0,
        created_at: now,
        updated_at: now
      }
    end

    def raw_price_attributes(plan:, lemon_variant_id:, **overrides)
      now = Time.current
      {
        plan_id: plan.id,
        billing_interval: "monthly",
        currency: "EUR",
        amount_cents: 1_000,
        lemon_store_id: "store-two",
        lemon_product_id: "product-two",
        lemon_variant_id: lemon_variant_id,
        active: true,
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def raw_unmapped_price_attributes(plan:, **overrides)
      raw_price_attributes(plan: plan, lemon_variant_id: "temporary-variant").merge(
        lemon_store_id: nil,
        lemon_product_id: nil,
        lemon_variant_id: nil
      ).merge(overrides)
    end
end
