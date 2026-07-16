require "test_helper"

class Catalog::SeedLocalCatalogTest < ActiveSupport::TestCase
  PRODUCT_KEYS = %w[analytics core crm].freeze
  PLAN_KEYS = %w[professional starter].freeze
  ANALYTICS_FEATURE_KEYS = %w[csv_export custom_reports dashboards report_limit].freeze

  test "the database seed loads the exact local catalog identities" do
    Rails.application.load_seed

    assert_equal [
      [ "analytics", "Analytics", "Analytics product for local development and tests.", true ],
      [ "core", "Core", "Core product for local development and tests.", true ],
      [ "crm", "CRM", "CRM product for local development and tests.", true ]
    ], Product.where(key: PRODUCT_KEYS).order(:key).pluck(:key, :name, :description, :active)
    assert_equal [
      [ "starter", "Starter", "Starter plan for local development and tests.", true, true, 10 ],
      [ "professional", "Professional", "Professional plan for local development and tests.", true, false, 20 ]
    ], Plan.where(key: PLAN_KEYS).order(:position).pluck(
      :key, :name, :description, :active, :free, :position
    )
    assert_equal [
      [ "csv_export", "CSV export", "Export Analytics reports as CSV files.", "flag", true ],
      [ "custom_reports", "Custom reports", "Create and view custom Analytics reports.", "flag", true ],
      [ "dashboards", "Dashboards", "View Analytics dashboards.", "flag", true ],
      [
        "report_limit",
        "Report limit",
        "Maximum number of Analytics reports for an organization.",
        "limit",
        true
      ]
    ], analytics_features.order(:key).pluck(:key, :name, :description, :kind, :active)
    assert_empty PlanProduct.joins(:product).where(products: { key: PRODUCT_KEYS })
    assert_empty PlanFeatureEntitlement.joins(:product).where(products: { key: PRODUCT_KEYS })
    assert_empty PlanPrice.joins(:plan).where(plans: { key: PLAN_KEYS })
  end

  test "repeated seeds converge mutable metadata without changing stable identities" do
    service = Catalog::SeedLocalCatalog.new
    service.call
    product_ids = Product.where(key: PRODUCT_KEYS).order(:key).pluck(:id)
    plan_ids = Plan.where(key: PLAN_KEYS).order(:key).pluck(:id)
    feature_ids = analytics_features.order(:key).pluck(:id)

    Product.find_by!(key: "core").update!(
      name: "Renamed Core",
      description: "Changed description.",
      active: false
    )
    Plan.find_by!(key: "starter").update!(
      name: "Renamed Starter",
      description: "Changed description.",
      active: false,
      free: false,
      position: 99
    )
    Plan.find_by!(key: "professional").update!(free: true)
    ProductFeature.find_by!(product: Product.find_by!(key: "analytics"), key: "dashboards").update!(
      name: "Renamed dashboards",
      description: "Changed feature description.",
      active: false
    )

    2.times { assert service.call }

    assert_equal product_ids, Product.where(key: PRODUCT_KEYS).order(:key).pluck(:id)
    assert_equal plan_ids, Plan.where(key: PLAN_KEYS).order(:key).pluck(:id)
    assert_equal feature_ids, analytics_features.order(:key).pluck(:id)
    assert_equal [ "Core", "Core product for local development and tests.", true ],
      Product.find_by!(key: "core").values_at(:name, :description, :active)
    assert_equal [ "Starter", "Starter plan for local development and tests.", true, true, 10 ],
      Plan.find_by!(key: "starter").values_at(:name, :description, :active, :free, :position)
    assert_equal [ "Professional", true, false, 20 ],
      Plan.find_by!(key: "professional").values_at(:name, :active, :free, :position)
    assert_equal [ "Dashboards", "View Analytics dashboards.", "flag", true ],
      ProductFeature.find_by!(
        product: Product.find_by!(key: "analytics"),
        key: "dashboards"
      ).values_at(:name, :description, :kind, :active)
  end

  test "the local catalog seed is a no-op outside development and test" do
    remove_seed_records
    non_local_seed = Class.new(Catalog::SeedLocalCatalog) do
      private
        def local_environment?
          false
        end
    end

    assert_not non_local_seed.new.call

    assert_empty Product.where(key: PRODUCT_KEYS)
    assert_empty Plan.where(key: PLAN_KEYS)
    assert_empty analytics_features
  end

  test "a failed seed rolls back every catalog record" do
    remove_seed_records
    Plan.create!(
      key: "existing_free",
      name: "Existing Free",
      active: true,
      free: true,
      position: 1
    )

    assert_raises(ActiveRecord::RecordInvalid) { Catalog::SeedLocalCatalog.new.call }

    assert_empty Product.where(key: PRODUCT_KEYS)
    assert_empty Plan.where(key: PLAN_KEYS)
  end

  test "fails closed when an existing stable feature has another kind" do
    service = Catalog::SeedLocalCatalog.new
    service.call
    analytics = Product.find_by!(key: "analytics")
    analytics.product_features.find_by!(key: "dashboards").delete
    analytics.product_features.create!(
      key: "dashboards",
      name: "Wrong dashboards",
      description: "Synthetic kind conflict.",
      kind: :limit,
      active: true
    )

    error = assert_raises(ActiveRecord::RecordInvalid) { service.call }

    assert_includes error.record.errors[:kind], "does not match the reviewed feature identity"
    assert_predicate error.record, :limit?
  end

  private
    def remove_seed_records
      Plan.where(key: PLAN_KEYS).delete_all
      ProductFeature.joins(:product).where(
        products: { key: PRODUCT_KEYS }
      ).delete_all
      Product.where(key: PRODUCT_KEYS).delete_all
    end

    def analytics_features
      ProductFeature.joins(:product).where(
        products: { key: "analytics" },
        product_features: { key: ANALYTICS_FEATURE_KEYS }
      )
    end
end
