require "test_helper"
require_relative "../../support/catalog_test_helper"
require_relative "../../support/organization_test_helper"

class Entitlements::UsageAndLimitEnforcerTest < ActiveSupport::TestCase
  include CatalogTestHelper
  include OrganizationTestHelper

  setup do
    suffix = SecureRandom.hex(6)
    @owner = create_test_user(email_address: "usage-owner-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Usage Tenant #{suffix}",
      slug: "usage-tenant-#{suffix}"
    )
    @analytics = Product.find_or_create_by!(key: "analytics") do |product|
      product.name = "Analytics"
      product.description = "Synthetic Analytics usage product."
      product.active = true
    end
    create_test_product_feature(
      product: @analytics,
      key: "report_limit",
      name: "Report limit",
      kind: :limit
    ) unless @analytics.product_features.exists?(key: "report_limit")
    @seat_product = create_test_product(
      key: "seat_usage_#{suffix}",
      name: "Seat usage product"
    )
    create_test_product_feature(
      product: @seat_product,
      key: Entitlements::Usage::SEAT_FEATURE_KEY,
      name: "Seat limit",
      kind: :limit
    )
    Current.organization = @organization
  end

  teardown { Current.reset }

  test "measures tenant reports and returns immutable finite remediation details" do
    @organization.analytics_reports.create!(name: "Older report")
    @organization.analytics_reports.create!(name: "Newest report")
    foreign_owner = create_test_user(email_address: "usage-foreign-#{SecureRandom.hex(5)}@example.test")
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign usage tenant",
      slug: "foreign-usage-#{SecureRandom.hex(5)}"
    )
    3.times { |index| foreign_organization.analytics_reports.create!(name: "Foreign report #{index}") }

    usage = measure_report(limit: 1)

    assert_equal 2, usage.used
    assert_equal 1, usage.limit
    assert_equal "reports", usage.unit
    assert_equal 0, usage.remaining
    assert_equal 1, usage.overage
    assert_predicate usage, :over_limit?
    assert_predicate usage, :exhausted?
    assert_equal [ "Newest report" ], usage.remediation_items.map(&:label)
    assert_predicate usage, :frozen?
    assert_predicate usage.remediation_items, :frozen?
    assert_predicate usage.remediation_items.sole, :frozen?
  end

  test "counts active product memberships as seats including owners and excluding suspended members" do
    member = create_test_user(email_address: "usage-member-#{SecureRandom.hex(5)}@example.test")
    member_membership = create_test_membership(
      organization: @organization,
      user: member,
      role: :member
    )
    @organization.product_memberships.create!(
      organization_membership: @owner_membership,
      product: @seat_product,
      status: :active
    )
    @organization.product_memberships.create!(
      organization_membership: member_membership,
      product: @seat_product,
      status: :suspended
    )

    usage = Entitlements::Usage.measure(
      organization: @organization,
      product_key: @seat_product.key,
      feature_key: Entitlements::Usage::SEAT_FEATURE_KEY,
      limit: 0
    )

    assert_equal 1, usage.used
    assert_equal "seats", usage.unit
    assert_equal 1, usage.overage
    assert_equal [ @owner.name ], usage.remediation_items.map(&:label)
  end

  test "enforcer allows exact boundary and unlimited then raises typed finite errors" do
    @organization.analytics_reports.create!(name: "Existing report")

    exact = enforcer(capacity: 2).enforce!(delta: 1)
    unlimited = enforcer(capacity: Entitlements::Usage::UNLIMITED).enforce!(delta: 100)
    reached = assert_raises(Entitlements::LimitExceeded) do
      enforcer(capacity: 1).enforce!(delta: 1)
    end
    over_limit = assert_raises(Entitlements::OverLimit) do
      enforcer(capacity: 0).enforce!(delta: 1)
    end

    assert_predicate exact, :allows?
    assert_predicate unlimited, :unlimited?
    assert_equal :limit_exceeded, reached.reason_code
    assert_equal [ "Existing report" ], reached.remediation_items.map(&:label)
    assert_equal :over_limit, over_limit.reason_code
    assert_equal 1, over_limit.usage.overage
  end

  test "fails closed for malformed capacity, unknown usage definitions, and cross-tenant context" do
    assert_raises(ArgumentError) { enforcer(capacity: -1).status }
    @analytics.product_features.find_by!(key: "report_limit").update!(active: false)
    inactive = enforcer(capacity: Entitlements::Usage::UNLIMITED).status
    assert_equal 0, inactive.limit
    @analytics.product_features.find_by!(key: "report_limit").update!(active: true)

    assert_raises(Entitlements::Usage::DefinitionMissing) do
      Entitlements::Usage.measure(
        organization: @organization,
        product_key: @seat_product.key,
        feature_key: "unknown_limit",
        limit: 1
      )
    end

    foreign_owner = create_test_user(email_address: "wrong-context-#{SecureRandom.hex(5)}@example.test")
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Wrong context",
      slug: "wrong-context-#{SecureRandom.hex(5)}"
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      Entitlements::Usage.measure(
        organization: foreign_organization,
        product_key: "analytics",
        feature_key: "report_limit",
        limit: 1
      )
    end
  end

  private
    def measure_report(limit:)
      Entitlements::Usage.measure(
        organization: @organization,
        product_key: "analytics",
        feature_key: "report_limit",
        limit: limit
      )
    end

    def enforcer(capacity:)
      Entitlements::LimitEnforcer.new(
        organization: @organization,
        product_key: "analytics",
        feature_key: "report_limit",
        capacity: capacity
      )
    end
end
