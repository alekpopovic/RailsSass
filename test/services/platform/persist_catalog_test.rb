require "test_helper"
require_relative "../../support/billing_test_helper"

class Platform::PersistCatalogTest < ActiveSupport::TestCase
  include BillingTestHelper

  setup do
    @actor = create_test_user(email_address: "catalog-persist-admin@example.test")
    @actor.update!(system_role: :platform_admin)
    Current.session, = Session.issue_for!(
      @actor,
      ip_address: nil,
      user_agent: "Platform catalog test"
    )
  end

  teardown do
    Current.reset
  end

  test "creates every supported catalog record with stable audit subject keys" do
    product = persist(Product.new, {
      key: unique_catalog_key("audited_product"),
      name: "Audited Product",
      description: "Created through the platform catalog boundary.",
      active: true
    })
    feature = persist(product.product_features.new, {
      key: unique_catalog_key("audited_feature"),
      name: "Audited Feature",
      description: "Created through the platform catalog boundary.",
      kind: :flag,
      active: true
    })
    plan = persist(Plan.new, {
      key: unique_catalog_key("audited_plan"),
      name: "Audited Plan",
      description: "Created through the platform catalog boundary.",
      active: true,
      free: false,
      position: 30
    })
    plan_product = persist(plan.plan_products.new(product: product), {})
    entitlement = persist(plan_product.plan_feature_entitlements.new(product_feature: feature), {
      enabled: true,
      unlimited: false,
      settings: {}
    })
    price = persist(plan.plan_prices.new, {
      billing_interval: :monthly,
      currency: "EUR",
      amount_cents: 2_000,
      active: true
    })

    assert_predicate product, :persisted?
    assert_predicate feature, :persisted?
    assert_predicate plan, :persisted?
    assert_predicate plan_product, :persisted?
    assert_predicate entitlement, :persisted?
    assert_predicate price, :persisted?

    events = @actor.platform_audit_events_as_actor.order(:id)
    assert_equal Array.new(6, "catalog.created"), events.pluck(:action)
    assert_equal [
      product.key,
      "#{product.key}/#{feature.key}",
      plan.key,
      "#{plan.key}/#{product.key}",
      "#{plan.key}/#{product.key}/#{feature.key}",
      "#{plan.key}/price/#{price.id}"
    ], events.pluck(:subject_key)
  end

  test "derives update and deactivate actions from the committed transition" do
    product = create_test_product(name: "Original Name")

    persist(product, { name: "Updated Name" })
    persist(product, { active: false })

    events = @actor.platform_audit_events_as_actor.order(:id)
    assert_equal %w[catalog.updated catalog.deactivated], events.pluck(:action)
    assert_equal({ "from" => "Original Name", "to" => "Updated Name" },
      events.first.change_set.fetch("name"))
    assert_equal({ "from" => true, "to" => false },
      events.second.change_set.fetch("active"))
  end

  test "keeps global catalog audit separate from tenant audit ledgers" do
    product = Product.new(
      key: unique_catalog_key("global_only"),
      name: "Global Catalog Product",
      description: "A platform-owned catalog record.",
      active: true
    )

    assert_no_difference -> { AuditEvent.count } do
      assert_difference -> { Platform::AuditEvent.count }, 1 do
        persist(product, {})
      end
    end

    assert_equal "catalog.created", Platform::AuditEvent.order(:id).last.action
  end

  test "rejects stable identity attributes on update without partially applying changes" do
    product = create_test_product(name: "Stable Product")
    original_key = product.key

    assert_no_difference -> { Platform::AuditEvent.count } do
      persist(product, { key: unique_catalog_key("changed"), name: "Changed Name" })
    end

    assert_includes product.errors[:key], "cannot be changed"
    assert_equal [ original_key, "Stable Product" ], product.reload.values_at(:key, :name)
  end

  test "uses a fixed immutable-identity allowlist for every supported record" do
    first_product = create_test_product
    second_product = create_test_product
    first_feature = create_test_product_feature(product: first_product)
    second_feature = create_test_product_feature(product: first_product)
    first_plan = create_test_plan
    second_plan = create_test_plan
    plan_product = create_test_plan_product(plan: first_plan, product: first_product)
    entitlement = create_test_entitlement(
      plan_product: plan_product,
      product_feature: first_feature
    )
    price = create_test_plan_price(plan: first_plan)

    attempts = [
      [ first_product, { key: unique_catalog_key("changed_product") }, :key ],
      [ first_feature, { product_id: second_product.id }, :product_id ],
      [ first_feature, { key: unique_catalog_key("changed_feature") }, :key ],
      [ first_feature, { kind: :limit }, :kind ],
      [ first_plan, { key: unique_catalog_key("changed_plan") }, :key ],
      [ plan_product, { product_id: second_product.id }, :product_id ],
      [ entitlement, { product_feature_id: second_feature.id }, :product_feature_id ],
      [ price, { plan_id: second_plan.id }, :plan_id ]
    ]

    assert_no_difference -> { Platform::AuditEvent.count } do
      attempts.each do |record, attributes, error_attribute|
        persist(record, attributes)
        assert_includes record.errors[error_attribute], "cannot be changed"
      end
    end

    assert_equal first_product.id, first_feature.reload.product_id
    assert_equal first_product.id, plan_product.reload.product_id
    assert_equal first_feature.id, entitlement.reload.product_feature_id
    assert_equal first_plan.id, price.reload.plan_id
  end

  test "fails closed for a non-admin unverified or disabled actor" do
    actors = [
      create_test_user(email_address: "catalog-ordinary@example.test"),
      create_test_user(email_address: "catalog-unverified@example.test", verified: false).tap do |user|
        user.update!(system_role: :platform_admin)
      end,
      create_test_user(
        email_address: "catalog-disabled@example.test",
        disabled_at: Time.current
      ).tap { |user| user.update!(system_role: :platform_admin) }
    ]

    actors.each do |actor|
      record = Product.new(key: unique_catalog_key("denied"), name: "Denied Product")

      assert_no_difference -> { Platform::AuditEvent.count } do
        Platform::PersistCatalog.new(actor: actor, record: record, attributes: {}).call
      end
      assert_not_predicate record, :persisted?
      assert_includes record.errors[:base], "platform administrator is required"
    end
  end

  test "rejects another platform administrator who is not the live Current user" do
    other_administrator = create_test_user(
      email_address: "catalog-other-admin@example.test"
    )
    other_administrator.update!(system_role: :platform_admin)
    record = Product.new(key: unique_catalog_key("wrong_actor"), name: "Wrong Actor")

    assert_no_difference -> { Platform::AuditEvent.count } do
      Platform::PersistCatalog.new(
        actor: other_administrator,
        record: record,
        attributes: {}
      ).call
    end

    assert_not_predicate record, :persisted?
    assert_includes record.errors[:base], "platform administrator is required"
  end

  test "rejects a platform administrator whose Current session was revoked" do
    revoked_session = Current.session
    Session.where(id: revoked_session.id).delete_all
    record = Product.new(key: unique_catalog_key("revoked"), name: "Revoked Actor")

    assert_no_difference -> { Platform::AuditEvent.count } do
      Platform::PersistCatalog.new(actor: @actor, record: record, attributes: {}).call
    end

    assert_predicate revoked_session, :persisted?
    assert_not_predicate record, :persisted?
    assert_includes record.errors[:base], "platform administrator is required"
  end

  test "returns entitlement consistency errors and rolls back the audit" do
    plan_product = create_test_plan_product(
      plan: create_test_plan,
      product: create_test_product
    )
    foreign_feature = create_test_product_feature(product: create_test_product)
    entitlement = plan_product.plan_feature_entitlements.new(
      product_feature: foreign_feature
    )

    assert_no_difference -> { Platform::AuditEvent.count } do
      persist(entitlement, { enabled: true, unlimited: false, settings: {} })
    end

    assert_not_predicate entitlement, :persisted?
    assert_includes entitlement.errors[:product_feature], "must belong to the plan product"
  end

  test "redacts arbitrary settings values while retaining bounded change evidence" do
    product = create_test_product
    feature = create_test_product_feature(product: product)
    plan_product = create_test_plan_product(plan: create_test_plan, product: product)
    entitlement = create_test_entitlement(
      plan_product: plan_product,
      product_feature: feature
    )

    persist(entitlement, { settings: { "operator_note" => "x" * 20_000 } })

    settings_change = @actor.platform_audit_events_as_actor.sole.change_set.fetch("settings")
    assert_equal true, settings_change.fetch("values_redacted")
    assert_equal 64, settings_change.dig("to", "sha256").length
    assert_operator JSON.generate(settings_change).bytesize, :<, 1_000
  end

  test "does not append an event for a no-op update" do
    product = create_test_product

    assert_no_difference -> { Platform::AuditEvent.count } do
      persist(product, { name: product.name })
    end
  end

  test "locks historically referenced price fields while allowing deactivation" do
    price = create_test_plan_price(plan: create_test_plan, amount_cents: 1_500)
    organization, = create_billing_tenant(prefix: "platform-price-lock")
    subscription = create_billing_subscription(organization:, plan_price: price)

    assert_no_difference -> { Platform::AuditEvent.count } do
      persist(price, { amount_cents: 9_999, active: false })
    end

    assert_includes price.errors[:amount_cents], "is not permitted"
    assert_includes price.errors[:base],
      "Billing history exists; only active status can be changed"
    assert_equal [ 1_500, true ], price.reload.values_at(:amount_cents, :active)

    price.errors.clear
    assert_difference -> { Platform::AuditEvent.where(action: "catalog.deactivated").count }, 1 do
      persist(price, { active: false })
    end

    assert_not price.reload.active?
    assert Billing::Subscription.exists?(subscription.id)
  end

  test "rejects unknown attributes and unsupported records" do
    product = create_test_product

    assert_no_difference -> { Platform::AuditEvent.count } do
      persist(product, { lemon_api_key: "not-a-real-key" })
    end
    assert_includes product.errors[:lemon_api_key], "is not permitted"

    error = assert_raises(ArgumentError) do
      Platform::PersistCatalog.new(actor: @actor, record: User.new, attributes: {}).call
    end
    assert_equal "unsupported catalog record", error.message
  end

  private
    def persist(record, attributes)
      Platform::PersistCatalog.new(
        actor: @actor,
        record: record,
        attributes: attributes
      ).call
    end
end
