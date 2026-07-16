require "test_helper"
require_relative "../../../support/billing_test_helper"

class Billing::PlanChanges::CreateTest < ActiveSupport::TestCase
  include BillingTestHelper

  STORE_ID = "72001"

  Snapshot = Data.define(
    :provider_subscription_id,
    :provider_customer_id,
    :provider_store_id,
    :provider_product_id,
    :provider_variant_id,
    :test_mode,
    :provider_updated_at
  )

  FakeClient = Struct.new(
    :snapshot,
    :error,
    :on_update,
    :environment,
    :store_id,
    :calls,
    keyword_init: true
  ) do
    def test_mode?
      environment == "test"
    end

    def update_subscription_variant(provider_subscription_id:, variant_id:)
      self.calls ||= []
      calls << {
        provider_subscription_id: provider_subscription_id,
        variant_id: variant_id
      }
      on_update&.call
      raise error if error

      snapshot
    end
  end

  setup do
    @now = Time.current.change(usec: 0)
    @organization, @owner_membership = create_billing_tenant(prefix: "plan-change-create")
    @owner = @owner_membership.user
    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )

    @source_plan = create_test_plan(name: "Source plan")
    @source_price, = create_mapped_price(plan: @source_plan)
    @target_plan = create_test_plan(name: "Target plan")
    @target_price, @target_mapping = create_mapped_price(plan: @target_plan)
    provider_customer_id = provider_numeric_id
    customer = create_billing_customer(
      organization: @organization,
      provider_customer_id: provider_customer_id
    )
    @subscription = create_billing_subscription(
      organization: @organization,
      billing_customer: customer,
      plan_price: @source_price,
      provider_customer_id: provider_customer_id,
      provider_subscription_id: "subscription_#{SecureRandom.hex(8)}",
      provider_updated_at: @now - 1.minute
    )
  end

  teardown { Current.reset }

  test "owner creates a pending command before one provider update without changing local access" do
    observed_pending = false
    client = fake_client(
      on_update: -> {
        change = @organization.billing_plan_changes.sole
        observed_pending = change.status_pending?
        assert_equal @source_price, @subscription.reload.plan_price
      }
    )

    result = create_change(client: client)

    assert observed_pending
    assert_not_predicate result, :duplicate?
    assert_predicate result.plan_change, :status_submitted?
    assert_equal @target_price, result.plan_change.to_plan_price
    assert_equal @source_price, @subscription.reload.plan_price
    assert_equal @source_plan, @organization.effective_plan
    assert_equal [ expected_provider_call ], client.calls
  end

  test "an active billing member can request a plan change" do
    billing_user = create_test_user(email_address: "billing-#{SecureRandom.hex(5)}@example.test")
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :billing
    )
    establish_tenant_context(
      user: billing_user,
      organization: @organization,
      membership: billing_membership
    )
    client = fake_client

    result = create_change(client: client, user: billing_user)

    assert_predicate result.plan_change, :status_submitted?
    assert_equal billing_membership, result.plan_change.requested_by_membership
    assert_equal 1, client.calls.size
  end

  test "member and cross-tenant contexts are denied before provider access" do
    member_user = create_test_user(email_address: "member-#{SecureRandom.hex(5)}@example.test")
    member = create_test_membership(
      organization: @organization,
      user: member_user,
      role: :member
    )
    establish_tenant_context(user: member_user, organization: @organization, membership: member)
    member_client = fake_client

    assert_raises(Pundit::NotAuthorizedError) do
      create_change(client: member_client, user: member_user)
    end
    assert_empty member_client.calls

    foreign_organization, foreign_membership = create_billing_tenant(prefix: "foreign-plan-change")
    establish_tenant_context(
      user: foreign_membership.user,
      organization: foreign_organization,
      membership: foreign_membership
    )
    cross_tenant_client = fake_client

    assert_raises(Pundit::NotAuthorizedError) do
      create_change(client: cross_tenant_client)
    end
    assert_empty cross_tenant_client.calls
    assert_empty @organization.billing_plan_changes
  end

  test "a same-target duplicate returns the open command without a second patch" do
    client = fake_client
    first = create_change(client: client)

    duplicate = create_change(client: client)

    assert_not_predicate first, :duplicate?
    assert_predicate duplicate, :duplicate?
    assert_equal first.plan_change, duplicate.plan_change
    assert_equal 1, @organization.billing_plan_changes.count
    assert_equal [ expected_provider_call ], client.calls
    assert_equal @source_price, @subscription.reload.plan_price
  end

  test "a provider timeout becomes creation unknown after exactly one patch" do
    client = fake_client(
      error: Billing::LemonSqueezy::Errors::TimeoutError.new(
        "Lemon Squeezy request timed out",
        retryable: true
      )
    )

    error = assert_raises(Billing::PlanChanges::Create::ProviderFailure) do
      create_change(client: client)
    end

    assert_predicate error, :ambiguous?
    assert_predicate error.plan_change.reload, :status_creation_unknown?
    assert_nil error.plan_change.completed_at
    assert_nil error.plan_change.failure_code
    assert_equal [ expected_provider_call ], client.calls
    assert_equal @source_price, @subscription.reload.plan_price
  end

  test "a definitive provider rejection fails with a safe code" do
    client = fake_client(
      error: Billing::LemonSqueezy::Errors::ClientError.new(
        "sensitive provider detail",
        status: 422
      )
    )

    error = assert_raises(Billing::PlanChanges::Create::ProviderFailure) do
      create_change(client: client)
    end

    assert_not_predicate error, :ambiguous?
    assert_equal "Plan change could not be confirmed safely", error.message
    assert_not_includes error.message, "sensitive provider detail"
    assert_predicate error.plan_change.reload, :status_failed?
    assert_equal "provider_rejected", error.plan_change.failure_code
    assert error.plan_change.completed_at
    assert_equal [ expected_provider_call ], client.calls
  end

  test "an explicit provider variant mismatch fails with its stable safe code" do
    client = fake_client(
      error: Billing::LemonSqueezy::Errors::VariantMismatchError.new(
        "sensitive mismatched variant",
        status: 200
      )
    )

    error = assert_raises(Billing::PlanChanges::Create::ProviderFailure) do
      create_change(client: client)
    end

    assert_not_predicate error, :ambiguous?
    assert_predicate error.plan_change.reload, :status_failed?
    assert_equal "provider_variant_mismatch", error.plan_change.failure_code
    assert_not_includes error.message, "sensitive mismatched variant"
    assert_equal [ expected_provider_call ], client.calls
  end

  test "a malformed successful response remains ambiguous and retry unsafe" do
    client = fake_client(
      error: Billing::LemonSqueezy::Errors::InvalidResponseError.new(
        "sensitive malformed response",
        status: 200
      )
    )

    error = assert_raises(Billing::PlanChanges::Create::ProviderFailure) do
      create_change(client: client)
    end

    assert_predicate error, :ambiguous?
    assert_predicate error.plan_change.reload, :status_creation_unknown?
    assert_equal [ expected_provider_call ], client.calls
  end

  test "an incompatible Analytics downgrade persists no command and sends no patch" do
    analytics = analytics_product
    report_limit = analytics_report_limit(analytics)
    add_limit(plan: @source_plan, product: analytics, feature: report_limit, limit: 5)
    add_limit(plan: @target_plan, product: analytics, feature: report_limit, limit: 1)
    2.times do |index|
      @organization.analytics_reports.create!(
        name: "Existing report #{index}",
        description: "Synthetic usage for downgrade preflight."
      )
    end
    client = fake_client

    error = assert_raises(Billing::PlanChanges::Create::IncompatiblePlan) do
      create_change(client: client)
    end

    assert_predicate error.compatibility, :incompatible?
    assert_predicate error.compatibility, :over_limit?
    assert_equal :downgrade, error.compatibility.classification
    assert_empty @organization.billing_plan_changes
    assert_empty client.calls
    assert_equal @source_price, @subscription.reload.plan_price
  end

  test "a webhook terminal transition before the response cannot regress to submitted" do
    response_time = @now + 1.second
    client = fake_client(
      on_update: -> {
        ApplicationRecord.transaction do
          subscription = @organization.billing_subscriptions.lock.find(@subscription.id)
          subscription.update!(
            plan_price: @target_price,
            provider_updated_at: response_time,
            last_seen_provider_updated_at: response_time
          )
          change = @organization.billing_plan_changes.open.lock.sole
          change.update!(
            status: :applied,
            provider_updated_at: response_time,
            completed_at: response_time
          )
        end
      }
    )

    result = create_change(client: client)

    assert_predicate result.plan_change.reload, :status_applied?
    assert_equal response_time.to_i, result.plan_change.provider_updated_at.to_i
    assert_equal response_time.to_i, result.plan_change.completed_at.to_i
    assert_equal @target_price, @subscription.reload.plan_price
    assert_equal [ expected_provider_call ], client.calls
  end

  private
    def create_change(client:, user: @owner)
      Billing::PlanChanges::Create.new(
        organization: @organization,
        user: user,
        plan_price: @target_price,
        compatibility_checker: Products::PlanCompatibility,
        client: client,
        now: @now
      ).call
    end

    def fake_client(snapshot: provider_snapshot, error: nil, on_update: nil)
      FakeClient.new(
        snapshot: snapshot,
        error: error,
        on_update: on_update,
        environment: "test",
        store_id: STORE_ID,
        calls: []
      )
    end

    def provider_snapshot
      Snapshot.new(
        provider_subscription_id: @subscription.provider_subscription_id,
        provider_customer_id: @subscription.provider_customer_id,
        provider_store_id: @target_mapping.provider_store_id,
        provider_product_id: @target_mapping.provider_product_id,
        provider_variant_id: @target_mapping.provider_variant_id,
        test_mode: true,
        provider_updated_at: @now + 1.second
      )
    end

    def expected_provider_call
      {
        provider_subscription_id: @subscription.provider_subscription_id,
        variant_id: @target_mapping.provider_variant_id
      }
    end

    def create_mapped_price(plan:)
      price = create_test_plan_price(
        plan: plan,
        lemon_store_id: STORE_ID,
        lemon_product_id: provider_numeric_id,
        lemon_variant_id: provider_numeric_id
      )
      [ price, create_billing_provider_price_mapping(plan_price: price) ]
    end

    def analytics_product
      Product.find_or_create_by!(key: "analytics") do |product|
        product.name = "Analytics"
        product.description = "Synthetic Analytics product."
        product.active = true
      end
    end

    def analytics_report_limit(product)
      product.product_features.find_or_create_by!(key: "report_limit") do |feature|
        feature.name = "Report limit"
        feature.description = "Synthetic report limit."
        feature.kind = :limit
        feature.active = true
      end
    end

    def add_limit(plan:, product:, feature:, limit:)
      plan_product = create_test_plan_product(plan: plan, product: product)
      create_test_entitlement(
        plan_product: plan_product,
        product_feature: feature,
        limit_value: limit
      )
    end
end
