require "test_helper"
require_relative "../../support/billing_test_helper"

class Entitlements::ResolverTest < ActiveSupport::TestCase
  include BillingTestHelper

  StaticCache = Struct.new(:value) do
    def fetch(*)
      value
    end
  end

  setup do
    @organization, @membership = create_billing_tenant(prefix: "entitlement-resolver")
    establish_tenant_context(
      user: @membership.user,
      organization: @organization,
      membership: @membership
    )
  end

  teardown do
    Current.reset
  end

  test "resolves paid product flags finite limits unlimited limits and deterministic product keys" do
    plan = create_test_plan(key: unique_catalog_key("professional"))
    core = create_test_product(key: unique_catalog_key("core"))
    analytics = create_test_product(key: unique_catalog_key("analytics"))
    flag = create_test_product_feature(product: core, key: unique_catalog_key("exports"))
    finite = create_test_product_feature(
      product: core,
      key: unique_catalog_key("seats"),
      kind: :limit
    )
    unlimited = create_test_product_feature(
      product: core,
      key: unique_catalog_key("reports"),
      kind: :limit
    )
    core_plan_product = create_test_plan_product(plan: plan, product: core)
    create_test_plan_product(plan: plan, product: analytics)
    create_test_entitlement(plan_product: core_plan_product, product_feature: flag)
    create_test_entitlement(
      plan_product: core_plan_product,
      product_feature: finite,
      limit_value: 0
    )
    create_test_entitlement(
      plan_product: core_plan_product,
      product_feature: unlimited,
      unlimited: true,
      limit_value: nil
    )
    subscription = create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan)
    )
    resolver = build_resolver

    assert_equal plan, resolver.effective_plan
    assert_equal plan, @organization.effective_plan
    assert resolver.product_enabled?(core.key)
    assert resolver.feature_enabled?(core.key, flag.key)
    assert resolver.feature_enabled?(core.key, finite.key)
    assert_nil resolver.limit(core.key, flag.key)
    assert_equal 0, resolver.limit(core.key, finite.key)
    assert_equal Entitlements::Result::UNLIMITED, resolver.limit(core.key, unlimited.key)
    assert_equal [ analytics.key, core.key ].sort, resolver.enabled_products

    explanation = resolver.explain(product_key: core.key, feature_key: unlimited.key)
    assert_instance_of Entitlements::Result, explanation
    assert_predicate explanation, :allowed?
    assert_predicate explanation, :unlimited?
    assert_equal :feature_enabled, explanation.reason_code
    assert_equal :limit, explanation.feature_kind
    assert_equal :paid, explanation.plan_source
    assert_equal plan.key, explanation.plan_key
    assert_equal :subscription_active,
      explanation.details.fetch(:subscription_reason_code)
    assert_predicate explanation, :frozen?
    assert_predicate explanation.details, :frozen?
    assert_equal subscription.cache_key_with_version,
      resolver.send(:plan_context).subscription.cache_key_with_version
  end

  test "returns distinct reasons for missing products features entitlements and disabled features" do
    plan = create_test_plan
    granted_product = create_test_product
    ungranted_product = create_test_product
    unconfigured_feature = create_test_product_feature(product: granted_product)
    disabled_feature = create_test_product_feature(product: granted_product)
    plan_product = create_test_plan_product(plan: plan, product: granted_product)
    create_test_entitlement(
      plan_product: plan_product,
      product_feature: disabled_feature,
      enabled: false
    )
    create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan)
    )
    resolver = build_resolver

    assert_explanation_reason resolver, "missing_product", nil, :product_not_found
    assert_explanation_reason resolver, ungranted_product.key, nil, :product_not_in_plan
    assert_explanation_reason resolver, granted_product.key, "missing_feature", :feature_not_found
    assert_explanation_reason(
      resolver,
      granted_product.key,
      unconfigured_feature.key,
      :feature_not_entitled
    )
    assert_explanation_reason(
      resolver,
      granted_product.key,
      disabled_feature.key,
      :feature_disabled
    )
    assert_not resolver.feature_enabled?(granted_product.key, nil)
    assert_not resolver.feature_enabled?(granted_product.key, "")
    assert_not resolver.product_enabled?(granted_product.name)
  end

  test "falls back to the active free plan for absent and inaccessible paid subscriptions" do
    free_plan = create_test_plan(key: unique_catalog_key("starter"), free: true)
    free_product = create_test_product(key: unique_catalog_key("core"))
    create_test_plan_product(plan: free_plan, product: free_product)
    resolver_without_subscription = build_resolver

    assert_equal free_plan, resolver_without_subscription.effective_plan
    assert resolver_without_subscription.product_enabled?(free_product.key)
    free_explanation = resolver_without_subscription.explain(product_key: free_product.key)
    assert_equal :free, free_explanation.plan_source
    assert_equal :no_current_subscription,
      free_explanation.details.fetch(:subscription_reason_code)

    paid_plan = create_test_plan(key: unique_catalog_key("professional"))
    paid_product = create_test_product(key: unique_catalog_key("analytics"))
    create_test_plan_product(plan: paid_plan, product: paid_product)
    subscription = create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: paid_plan)
    )
    now = Time.current
    blocked_states = {
      paused: [ {}, :subscription_paused ],
      unpaid: [ {}, :subscription_unpaid ],
      expired: [ {}, :subscription_expired ],
      unknown: [ {}, :subscription_unknown_status ],
      cancelled: [ { ends_at: now - 1.second }, :subscription_cancelled_ended ],
      past_due: [
        { past_due_started_at: now - 20.days, provider_updated_at: now },
        :subscription_past_due_grace_expired
      ]
    }

    blocked_states.each do |status, (attributes, reason_code)|
      subscription.update!({
        status: status,
        ends_at: nil,
        past_due_started_at: nil,
        provider_updated_at: now,
        last_seen_provider_updated_at: now
      }.merge(attributes))
      resolver = build_resolver(now: now)

      assert_equal free_plan, resolver.effective_plan, "expected free fallback for #{status}"
      assert resolver.product_enabled?(free_product.key)
      assert_not resolver.product_enabled?(paid_product.key)
      explanation = resolver.explain(product_key: free_product.key)
      assert_equal :free, explanation.plan_source
      assert_equal reason_code, explanation.details.fetch(:subscription_reason_code)
    end

    subscription.update!(
      plan_price: create_test_plan_price(plan: free_plan),
      status: "active",
      past_due_started_at: nil
    )
    free_subscription_result = build_resolver.explain(product_key: free_product.key)
    assert_equal :free, free_subscription_result.plan_source
    assert_equal :subscription_plan_is_free,
      free_subscription_result.details.fetch(:subscription_reason_code)
  end

  test "uses paid plans for accessible trial and past-due grace statuses" do
    plan = create_test_plan
    product = create_test_product
    create_test_plan_product(plan: plan, product: product)
    now = Time.current
    subscription = create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan),
      status: "on_trial",
      trial_ends_at: now - 1.day
    )

    trial_result = build_resolver(now: now).explain(product_key: product.key)
    assert_predicate trial_result, :allowed?
    assert_equal :paid, trial_result.plan_source
    assert_equal :subscription_on_trial,
      trial_result.details.fetch(:subscription_reason_code)

    subscription.update!(
      status: "past_due",
      trial_ends_at: nil,
      provider_updated_at: now,
      past_due_started_at: now - 1.day
    )
    past_due_result = build_resolver(now: now).explain(product_key: product.key)
    assert_predicate past_due_result, :allowed?
    assert_equal :paid, past_due_result.plan_source
    assert_equal :subscription_past_due_grace,
      past_due_result.details.fetch(:subscription_reason_code)
  end

  test "uses paid cancelled access before its end and free fallback at the exact boundary" do
    free_plan = create_test_plan(key: unique_catalog_key("starter"), free: true)
    paid_plan = create_test_plan(key: unique_catalog_key("professional"))
    product = create_test_product
    create_test_plan_product(plan: free_plan, product: product)
    create_test_plan_product(plan: paid_plan, product: product)
    ends_at = Time.current.change(usec: 0) + 1.day
    create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: paid_plan),
      status: "cancelled",
      ends_at: ends_at
    )
    cache = ActiveSupport::Cache::MemoryStore.new

    before_boundary = build_resolver(now: ends_at - Rational(1, 1_000_000), cache: cache)
    at_boundary = build_resolver(now: ends_at, cache: cache)

    assert_equal paid_plan, before_boundary.effective_plan
    assert_equal :paid, before_boundary.explain(product_key: product.key).plan_source
    assert_equal free_plan, at_boundary.effective_plan
    at_boundary_result = at_boundary.explain(product_key: product.key)
    assert_equal :free, at_boundary_result.plan_source
    assert_equal :subscription_cancelled_ended,
      at_boundary_result.details.fetch(:subscription_reason_code)
  end

  test "fails closed when neither an accessible paid plan nor active free plan exists" do
    create_test_plan(free: true, active: false)
    result = build_resolver.explain(product_key: "core")

    assert_nil @organization.effective_plan
    assert_predicate result, :denied?
    assert_equal :no_effective_plan, result.reason_code
    assert_equal :no_current_subscription,
      result.details.fetch(:subscription_reason_code)
    assert_equal :active_free_plan_missing,
      result.details.fetch(:fallback_reason_code)
  end

  test "uses catalog active flags for selection only and not as an entitlement kill switch" do
    plan = create_test_plan
    product = create_test_product
    feature = create_test_product_feature(product: product)
    plan_product = create_test_plan_product(plan: plan, product: product)
    create_test_entitlement(plan_product: plan_product, product_feature: feature)
    price = create_test_plan_price(plan: plan)
    create_billing_subscription(
      organization: @organization,
      plan_price: price
    )
    plan.update!(active: false)
    price.update!(active: false)
    product.update!(active: false)
    feature.update!(active: false)

    resolver = build_resolver
    assert resolver.product_enabled?(product.key)
    assert resolver.feature_enabled?(product.key, feature.key)
  end

  test "rejects a foreign organization and never considers its subscription" do
    foreign_organization, = create_billing_tenant(prefix: "entitlement-resolver-foreign")
    foreign_plan = create_test_plan
    foreign_product = create_test_product
    create_test_plan_product(plan: foreign_plan, product: foreign_product)
    create_billing_subscription(
      organization: foreign_organization,
      plan_price: create_test_plan_price(plan: foreign_plan)
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      Entitlements::Resolver.new(organization: foreign_organization)
    end
    assert_raises(ActiveRecord::RecordNotFound) { foreign_organization.effective_plan }
    assert_nil build_resolver.effective_plan
  end

  test "invalid cached limit configuration fails closed" do
    plan = create_test_plan
    product = create_test_product
    feature = create_test_product_feature(product: product, kind: :limit)
    create_test_plan_product(plan: plan, product: product)
    create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan)
    )
    invalid_snapshot = {
      "products" => {
        product.key => {
          "granted" => true,
          "features" => {
            feature.key => { "kind" => "limit" }
          },
          "entitlements" => {
            feature.key => {
              "enabled" => true,
              "feature_kind" => "limit",
              "limit_value" => nil,
              "unlimited" => false,
              "product_matches" => true
            }
          }
        }
      }
    }
    resolver = build_resolver(cache: StaticCache.new(invalid_snapshot))
    result = resolver.explain(product_key: product.key, feature_key: feature.key)

    assert_predicate result, :denied?
    assert_equal :invalid_limit_configuration, result.reason_code
    assert_nil resolver.limit(product.key, feature.key)
  end

  test "malformed cached catalog structures return a denial instead of raising" do
    plan = create_test_plan
    product = create_test_product
    feature = create_test_product_feature(product: product)
    create_test_plan_product(plan: plan, product: product)
    create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan)
    )
    malformed_snapshot = {
      "products" => {
        product.key => {
          "granted" => true,
          "features" => nil,
          "entitlements" => nil
        },
        123 => { "granted" => true }
      }
    }
    resolver = build_resolver(cache: StaticCache.new(malformed_snapshot))
    result = resolver.explain(product_key: product.key, feature_key: feature.key)

    assert_predicate result, :denied?
    assert_equal :catalog_snapshot_invalid, result.reason_code
    assert_equal [ product.key ], resolver.enabled_products

    truthy_mismatch_snapshot = {
      "products" => {
        product.key => {
          "granted" => true,
          "features" => {
            feature.key => { "kind" => "flag" }
          },
          "entitlements" => {
            feature.key => {
              "enabled" => true,
              "feature_kind" => "flag",
              "limit_value" => nil,
              "unlimited" => false,
              "product_matches" => "false"
            }
          }
        }
      }
    }
    mismatch_result = build_resolver(
      cache: StaticCache.new(truthy_mismatch_snapshot)
    ).explain(product_key: product.key, feature_key: feature.key)

    assert_predicate mismatch_result, :denied?
    assert_equal :feature_kind_mismatch, mismatch_result.reason_code
  end

  test "cache keys version plan subscription and catalog rows and invalidate changed entitlements" do
    plan = create_test_plan
    product = create_test_product
    feature = create_test_product_feature(product: product)
    plan_product = create_test_plan_product(plan: plan, product: product)
    entitlement = create_test_entitlement(plan_product: plan_product, product_feature: feature)
    subscription = create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan)
    )
    cache = ActiveSupport::Cache::MemoryStore.new
    resolver = build_resolver(cache: cache)
    assert resolver.feature_enabled?(product.key, feature.key)
    initial_key = resolver.send(:entitlement_cache_key)

    entitlement.update!(enabled: false)
    entitlement_key = build_resolver(cache: cache).send(:entitlement_cache_key)
    assert_not_equal initial_key, entitlement_key
    assert_not build_resolver(cache: cache).feature_enabled?(product.key, feature.key)

    plan.touch
    plan_key = build_resolver(cache: cache).send(:entitlement_cache_key)
    assert_not_equal entitlement_key, plan_key

    subscription.touch
    subscription_key = build_resolver(cache: cache).send(:entitlement_cache_key)
    assert_not_equal plan_key, subscription_key

    product.update!(name: "Changed Product")
    product_key = build_resolver(cache: cache).send(:entitlement_cache_key)
    assert_not_equal subscription_key, product_key

    feature.update!(name: "Changed Feature")
    feature_key = build_resolver(cache: cache).send(:entitlement_cache_key)
    assert_not_equal product_key, feature_key
  end

  test "loads one catalog snapshot without queries per public lookup and never opens Lemon client" do
    plan = create_test_plan
    product = create_test_product
    plan_product = create_test_plan_product(plan: plan, product: product)
    features = 12.times.map do
      feature = create_test_product_feature(product: product)
      create_test_entitlement(plan_product: plan_product, product_feature: feature)
      feature
    end
    create_billing_subscription(
      organization: @organization,
      plan_price: create_test_plan_price(plan: plan)
    )
    single_resolver = build_resolver(cache: ActiveSupport::Cache::MemoryStore.new)
    single_lookup_queries = capture_sql do
      ApplicationRecord.uncached do
        single_resolver.feature_enabled?(product.key, features.first.key)
      end
    end

    resolver = build_resolver(cache: ActiveSupport::Cache::MemoryStore.new)
    all_lookup_queries = capture_sql do
      ApplicationRecord.uncached do
        features.each { |feature| resolver.feature_enabled?(product.key, feature.key) }
        resolver.enabled_products
      end
    end

    assert_predicate single_lookup_queries.length, :positive?
    assert_equal single_lookup_queries.length, all_lookup_queries.length
    assert_not_requested :any, %r{\Ahttps://api\.lemonsqueezy\.com/}

    repeated_queries = capture_sql do
      5.times do
        features.each { |feature| resolver.explain(product_key: product.key, feature_key: feature.key) }
      end
    end
    assert_empty repeated_queries
  end

  private
    def build_resolver(now: Time.current, cache: Rails.cache)
      Entitlements::Resolver.new(
        organization: @organization,
        now: now,
        cache: cache
      )
    end

    def assert_explanation_reason(resolver, product_key, feature_key, expected_reason)
      result = resolver.explain(product_key: product_key, feature_key: feature_key)
      assert_predicate result, :denied?
      assert_equal expected_reason, result.reason_code
    end

    def capture_sql
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries
    end
end
