require "test_helper"

class Catalog::SeedLocalCatalogTest < ActiveSupport::TestCase
  PRODUCT_KEYS = %w[analytics core crm].freeze
  PLAN_KEYS = %w[professional starter].freeze

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
  end

  test "repeated seeds converge mutable metadata without changing stable identities" do
    service = Catalog::SeedLocalCatalog.new
    service.call
    product_ids = Product.where(key: PRODUCT_KEYS).order(:key).pluck(:id)
    plan_ids = Plan.where(key: PLAN_KEYS).order(:key).pluck(:id)

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

    2.times { assert service.call }

    assert_equal product_ids, Product.where(key: PRODUCT_KEYS).order(:key).pluck(:id)
    assert_equal plan_ids, Plan.where(key: PLAN_KEYS).order(:key).pluck(:id)
    assert_equal [ "Core", "Core product for local development and tests.", true ],
      Product.find_by!(key: "core").values_at(:name, :description, :active)
    assert_equal [ "Starter", "Starter plan for local development and tests.", true, true, 10 ],
      Plan.find_by!(key: "starter").values_at(:name, :description, :active, :free, :position)
    assert_equal [ "Professional", true, false, 20 ],
      Plan.find_by!(key: "professional").values_at(:name, :active, :free, :position)
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

  private
    def remove_seed_records
      Plan.where(key: PLAN_KEYS).delete_all
      Product.where(key: PRODUCT_KEYS).delete_all
    end
end
