require "test_helper"
require_relative "../support/catalog_test_helper"

class PlanTest < ActiveSupport::TestCase
  include CatalogTestHelper

  test "normalizes stable key and orders plans by an explicit nonnegative position" do
    plan = Plan.create!(
      key: "  PROFESSIONAL_PLUS  ",
      name: "  Professional Plus  ",
      description: "  Expanded local catalog plan.  ",
      position: 20
    )

    assert_equal "professional_plus", plan.key
    assert_equal "Professional Plus", plan.name
    assert_equal "Expanded local catalog plan.", plan.description
    assert_equal 20, plan.position
    assert_not plan.free?
    assert_not Plan.new(key: "negative", name: "Negative", position: -1).valid?
  end

  test "validates only one active free plan while allowing inactive free history" do
    Plan.find_by(active: true, free: true) || create_test_plan(free: true, active: true)

    conflicting = Plan.new(key: unique_catalog_key("free"), name: "Other Free", free: true)
    inactive = Plan.new(
      key: unique_catalog_key("retired_free"),
      name: "Inactive Free",
      free: true,
      active: false
    )

    assert_not conflicting.valid?
    assert_includes conflicting.errors[:free], "already has an active plan"
    assert_predicate inactive, :valid?
  end

  test "stable key is readonly after creation" do
    plan = create_test_plan

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      plan.update!(key: unique_catalog_key("changed_plan"))
    end
  end
end
