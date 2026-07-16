require "test_helper"
require_relative "../support/billing_test_helper"

class AdminInterfaceTest < ActionDispatch::IntegrationTest
  include BillingTestHelper

  setup do
    @product = create_test_product(
      key: "admin_interface_product",
      name: "Admin Interface Product"
    )
    @feature = create_test_product_feature(
      product: @product,
      key: "admin_interface_flag",
      name: "Admin Interface Flag"
    )
    @plan = create_test_plan(
      key: "admin_interface_plan",
      name: "Admin Interface Plan"
    )
    @plan_product = create_test_plan_product(plan: @plan, product: @product)
    @plan_price = create_test_plan_price(plan: @plan)
  end

  test "every admin page requires authentication and direct mutations remain unchanged" do
    subscription, webhook_event = diagnostic_records

    admin_get_paths(subscription:, webhook_event:).each do |path|
      get path

      assert_redirected_to new_session_path
    end

    assert_no_changes -> { @product.reload.attributes.slice("key", "name", "active") } do
      patch admin_product_path(@product.key), params: {
        product: { name: "Unauthenticated mutation", active: "0" }
      }
    end

    assert_redirected_to new_session_path
  end

  test "a platform administrator can render every admin page" do
    sign_in_as_platform_admin
    subscription, webhook_event = diagnostic_records

    admin_get_paths(subscription:, webhook_event:).each do |path|
      get path

      assert_response :success, "expected #{path} to render"
    end
  end

  test "ordinary users and organization owners receive no admin list or detail" do
    subscription, webhook_event = diagnostic_records
    ordinary_user = create_test_user(email_address: "admin-interface-ordinary@example.test")
    owner = create_test_user(email_address: "admin-interface-owner@example.test")
    create_test_organization_with_owner(
      owner: owner,
      name: "Admin Interface Owner Organization",
      slug: "admin-interface-owner-organization"
    )
    denied_paths = admin_get_paths(subscription:, webhook_event:)

    [ ordinary_user, owner ].each do |actor|
      sign_in_as(actor)

      denied_paths.each do |path|
        get path

        assert_generic_forbidden
        assert_no_match @product.name, response.body
      end

      assert_no_changes -> { @product.reload.name } do
        patch admin_product_path(@product.key), params: {
          product: { name: "Forbidden mutation", active: "1" }
        }
      end
      assert_generic_forbidden

      get root_path
      assert_response :success
      assert_select "a[href=?]", admin_root_path, count: 0

      delete session_path
    end
  end

  test "a live role revocation blocks the next admin request" do
    administrator = sign_in_as_platform_admin

    get admin_products_path
    assert_response :success

    User.where(id: administrator.id).update_all(system_role: "user", updated_at: Time.current)

    get admin_product_path(@product.key)
    assert_generic_forbidden
    assert_no_match @product.name, response.body

    get root_path
    assert_response :success
    assert_select "a[href=?]", admin_root_path, count: 0
  end

  test "platform administrator creates updates and deactivates products and product features with stable keys" do
    sign_in_as_platform_admin
    product_key = "managed_admin_product"

    get root_path
    assert_response :success
    assert_select "a[href=?]", admin_root_path, "Admin"

    assert_difference -> { Product.count }, 1 do
      assert_difference -> { Platform::AuditEvent.where(action: "catalog.created").count }, 1 do
        post admin_products_path, params: {
          product: {
            key: product_key,
            name: "Managed Admin Product",
            description: "Created through the platform interface.",
            active: "1"
          }
        }
      end
    end

    product = Product.find_by!(key: product_key)
    assert_redirected_to admin_product_path(product_key)

    assert_difference -> { Platform::AuditEvent.where(action: "catalog.deactivated").count }, 1 do
      patch admin_product_path(product_key), params: {
        product: {
          key: "attempted_product_rekey",
          name: "Managed Admin Product Updated",
          description: "Updated through the platform interface.",
          active: "0"
        }
      }
    end

    assert_redirected_to admin_product_path(product_key)
    assert_equal product_key, product.reload.key
    assert_equal "Managed Admin Product Updated", product.name
    assert_not product.active?

    feature_key = "managed_flag"
    assert_difference -> { product.product_features.count }, 1 do
      post admin_product_features_path(product_key), params: {
        product_feature: {
          key: feature_key,
          name: "Managed Flag",
          description: "A managed boolean feature.",
          kind: "flag",
          active: "1"
        }
      }
    end

    feature = product.product_features.find_by!(key: feature_key)
    assert_redirected_to admin_product_feature_path(product_key, feature_key)

    patch admin_product_feature_path(product_key, feature_key), params: {
      product_feature: {
        key: "attempted_feature_rekey",
        kind: "limit",
        product_id: @product.id,
        name: "Managed Flag Updated",
        description: "Still a flag with its original stable identity.",
        active: "0"
      }
    }

    assert_redirected_to admin_product_feature_path(product_key, feature_key)
    assert_equal feature_key, feature.reload.key
    assert_predicate feature, :flag?
    assert_equal product.id, feature.product_id
    assert_equal "Managed Flag Updated", feature.name
    assert_not feature.active?
  end

  test "platform administrator manages the plan graph and deactivates referenced prices without deleting history" do
    sign_in_as_platform_admin
    plan_key = "managed_admin_plan"

    assert_difference -> { Plan.count }, 1 do
      post admin_plans_path, params: {
        plan: {
          key: plan_key,
          name: "Managed Admin Plan",
          description: "Created through the platform interface.",
          active: "1",
          free: "0",
          position: "30"
        }
      }
    end

    plan = Plan.find_by!(key: plan_key)
    assert_redirected_to admin_plan_path(plan_key)

    patch admin_plan_path(plan_key), params: {
      plan: {
        key: "attempted_plan_rekey",
        name: "Managed Admin Plan Updated",
        description: "Stable plan identity retained.",
        active: "1",
        free: "0",
        position: "40"
      }
    }

    assert_redirected_to admin_plan_path(plan_key)
    assert_equal plan_key, plan.reload.key
    assert_equal "Managed Admin Plan Updated", plan.name
    assert_equal 40, plan.position
    assert_predicate plan, :active?

    assert_difference -> { PlanProduct.count }, 1 do
      post admin_plan_plan_products_path(plan_key), params: {
        plan_product: { product_key: @product.key }
      }
    end

    plan_product = plan.plan_products.find_by!(product: @product)
    assert_redirected_to admin_plan_plan_product_path(plan_key, @product.key)

    assert_difference -> { PlanFeatureEntitlement.count }, 1 do
      post admin_create_plan_feature_entitlement_path(
        plan_key: plan_key,
        product_key: @product.key
      ), params: {
        plan_feature_entitlement: {
          feature_identity: "#{@product.key}/#{@feature.key}",
          enabled: "1",
          limit_value: "",
          unlimited: "0"
        }
      }
    end

    entitlement = plan_product.plan_feature_entitlements.find_by!(product_feature: @feature)
    assert_redirected_to admin_plan_feature_entitlement_path(
      plan_key: plan_key,
      product_key: @product.key,
      feature_key: @feature.key
    )
    assert_predicate entitlement, :enabled?
    assert_predicate entitlement, :flag?

    patch admin_plan_feature_entitlement_path(
      plan_key: plan_key,
      product_key: @product.key,
      feature_key: @feature.key
    ), params: {
      plan_feature_entitlement: {
        enabled: "0",
        limit_value: "",
        unlimited: "0"
      }
    }

    assert_redirected_to admin_plan_feature_entitlement_path(
      plan_key: plan_key,
      product_key: @product.key,
      feature_key: @feature.key
    )
    assert_not entitlement.reload.enabled?

    assert_difference -> { PlanPrice.count }, 1 do
      post admin_plan_plan_prices_path(plan_key), params: {
        plan_price: {
          billing_interval: "monthly",
          currency: "eur",
          amount_cents: "2500",
          active: "1"
        }
      }
    end

    price = plan.plan_prices.order(:id).last!
    assert_redirected_to admin_plan_plan_price_path(plan_key, price)

    patch admin_plan_path(plan_key), params: {
      plan: {
        name: plan.name,
        description: plan.description,
        active: "0",
        free: "0",
        position: plan.position.to_s
      }
    }
    assert_redirected_to admin_plan_path(plan_key)
    assert_not plan.reload.active?

    organization, = create_billing_tenant(prefix: "admin-price-history")
    subscription = create_billing_subscription(organization:, plan_price: price)

    original_commercial_fields = price.attributes.slice(
      "plan_id",
      "billing_interval",
      "currency",
      "amount_cents",
      "lemon_store_id",
      "lemon_product_id",
      "lemon_variant_id"
    )
    assert_no_changes -> { price.reload.attributes.slice(*original_commercial_fields.keys) } do
      patch admin_plan_plan_price_path(plan_key, price), params: {
        plan_price: {
          amount_cents: "9999",
          lemon_store_id: "replacement-store",
          lemon_product_id: "replacement-product",
          lemon_variant_id: "replacement-variant"
        }
      }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /only active status can be changed/i

    patch admin_plan_plan_price_path(plan_key, price), params: {
      plan_price: {
        active: "0"
      }
    }

    assert_redirected_to admin_plan_plan_price_path(plan_key, price)
    assert_equal plan.id, price.reload.plan_id
    assert_not price.active?
    assert Billing::Subscription.exists?(subscription.id)
    assert_predicate subscription.reload, :current?

    [
      admin_product_path(@product.key),
      admin_plan_path(plan.key),
      admin_plan_plan_price_path(plan.key, price)
    ].each do |path|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(path, method: :delete)
      end
    end
  end

  test "an inconsistent feature selection renders a validation error and persists nothing" do
    sign_in_as_platform_admin
    other_product = create_test_product(
      key: "admin_inconsistent_product",
      name: "Admin Inconsistent Product"
    )
    other_feature = create_test_product_feature(
      product: other_product,
      key: "foreign_flag",
      name: "Foreign Flag"
    )

    assert_no_difference [
      -> { PlanFeatureEntitlement.count },
      -> { Platform::AuditEvent.count }
    ] do
      post admin_create_plan_feature_entitlement_path(
        plan_key: @plan.key,
        product_key: @product.key
      ), params: {
        plan_feature_entitlement: {
          feature_identity: "#{other_product.key}/#{other_feature.key}",
          enabled: "1",
          limit_value: "",
          unlimited: "0"
        }
      }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /must belong to the plan product/i

    entitlement = create_test_entitlement(
      plan_product: @plan_product,
      product_feature: @feature,
      settings: { "api_key" => "ENTITLEMENT_SECRET_SENTINEL" }
    )
    get admin_edit_plan_feature_entitlement_path(
      plan_key: @plan.key,
      product_key: @product.key,
      feature_key: entitlement.product_feature.key
    )

    assert_response :success
    assert_no_match "ENTITLEMENT_SECRET_SENTINEL", response.body
    assert_select "textarea[name='plan_feature_entitlement[settings]']", count: 0
  end

  test "inactive catalog records cannot be attached through direct admin posts" do
    sign_in_as_platform_admin
    inactive_product = create_test_product(
      key: "admin_inactive_product",
      name: "Admin Inactive Product",
      active: false
    )
    inactive_feature = create_test_product_feature(
      product: @product,
      key: "admin_inactive_feature",
      name: "Admin Inactive Feature",
      active: false
    )
    inactive_plan = create_test_plan(
      key: "admin_inactive_plan",
      name: "Admin Inactive Plan",
      active: false
    )
    inactive_plan_product = create_test_plan_product(plan: inactive_plan, product: @product)

    assert_no_difference [ -> { PlanProduct.count }, -> { Platform::AuditEvent.count } ] do
      post admin_plan_plan_products_path(@plan.key), params: {
        plan_product: { product_key: inactive_product.key }
      }
    end
    assert_response :not_found

    assert_no_difference [
      -> { PlanFeatureEntitlement.count },
      -> { Platform::AuditEvent.count }
    ] do
      post admin_create_plan_feature_entitlement_path(
        plan_key: @plan.key,
        product_key: @product.key
      ), params: {
        plan_feature_entitlement: {
          feature_identity: "#{@product.key}/#{inactive_feature.key}",
          enabled: "1",
          limit_value: "",
          unlimited: "0"
        }
      }
    end
    assert_response :not_found

    assert_no_difference [ -> { PlanProduct.count }, -> { Platform::AuditEvent.count } ] do
      post admin_plan_plan_products_path(inactive_plan.key), params: {
        plan_product: { product_key: inactive_product.key }
      }
    end
    assert_response :not_found

    assert_no_difference [ -> { PlanPrice.count }, -> { Platform::AuditEvent.count } ] do
      post admin_plan_plan_prices_path(inactive_plan.key), params: {
        plan_price: {
          billing_interval: "monthly",
          currency: "EUR",
          amount_cents: "1000",
          active: "1"
        }
      }
    end
    assert_response :not_found

    assert_no_difference [
      -> { PlanFeatureEntitlement.count },
      -> { Platform::AuditEvent.count }
    ] do
      post admin_create_plan_feature_entitlement_path(
        plan_key: inactive_plan.key,
        product_key: inactive_plan_product.product.key
      ), params: {
        plan_feature_entitlement: {
          feature_identity: "#{@product.key}/#{@feature.key}",
          enabled: "1",
          limit_value: "",
          unlimited: "0"
        }
      }
    end
    assert_response :not_found
  end

  test "subscription diagnostics remain tenant rooted and omit sensitive persisted fields" do
    sign_in_as_platform_admin
    first_plan = create_test_plan(key: "admin_diagnostic_first", name: "First Diagnostic Plan")
    second_plan = create_test_plan(key: "admin_diagnostic_second", name: "Second Diagnostic Plan")
    first_price = create_test_plan_price(plan: first_plan)
    second_price = create_test_plan_price(plan: second_plan)
    first_organization, = create_billing_tenant(prefix: "admin-diagnostic-first")
    second_organization, = create_billing_tenant(prefix: "admin-diagnostic-second")
    first_subscription = create_billing_subscription(
      organization: first_organization,
      plan_price: first_price,
      pause: { "mode" => "PAUSE_PAYLOAD_SENTINEL" },
      card_brand: "CARD_SENTINEL",
      card_last_four: "4242",
      raw_payload: { "status" => "RAW_PAYLOAD_SENTINEL" }
    )
    second_subscription = create_billing_subscription(
      organization: second_organization,
      plan_price: second_price
    )

    get admin_billing_subscriptions_path

    assert_response :success
    assert_select "input[name='organization_public_id']"
    assert_select "select[name='organization_public_id']", count: 0
    assert_no_match first_organization.name, response.body
    assert_no_match second_organization.name, response.body

    get admin_billing_subscriptions_path(
      organization_public_id: first_organization.public_id
    )

    assert_response :success
    assert_select "input[name='organization_public_id'][value=?]", first_organization.public_id
    assert_match first_plan.key, response.body
    assert_no_match second_plan.key, response.body
    assert_no_match "RAW_PAYLOAD_SENTINEL", response.body

    get admin_billing_subscription_path(
      first_subscription,
      organization_public_id: first_organization.public_id
    )

    assert_response :success
    assert_match first_subscription.provider_subscription_id, response.body
    assert_no_match "RAW_PAYLOAD_SENTINEL", response.body
    assert_no_match "PAUSE_PAYLOAD_SENTINEL", response.body
    assert_no_match "CARD_SENTINEL", response.body

    get admin_billing_subscription_path(
      second_subscription,
      organization_public_id: first_organization.public_id
    )

    assert_response :not_found
    assert_select "title", "Page not found (404)"
    assert_no_match second_subscription.provider_subscription_id, response.body
    assert_nil Current.organization
  end

  test "failed webhook diagnostics filter other statuses and omit fingerprints and snapshots" do
    sign_in_as_platform_admin
    processed_at = 1.second.from_now
    failed_event = create_billing_webhook_event(
      status: "failed",
      event_name: "subscription_failed_projection",
      provider_event_id: "event_failed_admin_interface",
      provider_resource_id: "subscription_failed_admin_interface",
      processed_at: processed_at,
      error_code: "projection_failed",
      attempt_count: 3,
      snapshot: { "reason_code" => "WEBHOOK_SNAPSHOT_SENTINEL" }
    )
    processed_event = create_billing_webhook_event(
      status: "processed",
      event_name: "subscription_processed_projection",
      provider_event_id: "event_processed_admin_interface",
      provider_resource_id: "subscription_processed_admin_interface",
      processed_at: processed_at,
      snapshot: { "reason_code" => "PROCESSED_SNAPSHOT_SENTINEL" }
    )

    get admin_billing_webhook_events_path

    assert_response :success
    assert_match failed_event.event_name, response.body
    assert_match failed_event.error_code, response.body
    assert_no_match processed_event.event_name, response.body
    assert_no_match failed_event.fingerprint, response.body
    assert_no_match "WEBHOOK_SNAPSHOT_SENTINEL", response.body

    get admin_billing_webhook_event_path(failed_event)

    assert_response :success
    assert_match failed_event.provider_event_id, response.body
    assert_no_match failed_event.fingerprint, response.body
    assert_no_match "WEBHOOK_SNAPSHOT_SENTINEL", response.body

    get admin_billing_webhook_event_path(processed_event)

    assert_response :not_found
    assert_select "title", "Page not found (404)"
    assert_no_match processed_event.provider_event_id, response.body

    100.times do |index|
      create_billing_webhook_event(
        status: "failed",
        event_name: "paginated_failed_event_#{index}",
        processed_at: processed_at,
        error_code: "projection_failed"
      )
    end

    get admin_billing_webhook_events_path

    assert_response :success
    assert_select "tbody tr", count: 100
    assert_select "nav[aria-label='Failed webhook pages'] a", text: "Next"

    get admin_billing_webhook_events_path(page: 2)

    assert_response :success
    assert_select "tbody tr", count: 1
    assert_select "nav[aria-label='Failed webhook pages'] a", text: "Previous"
    assert_select "nav[aria-label='Failed webhook pages'] a", text: "Next", count: 0

    get admin_billing_webhook_events_path(page: 0)

    assert_response :not_found
    assert_select "title", "Page not found (404)"

    get admin_billing_webhook_events_path(page: 10_001)

    assert_response :not_found
    assert_select "title", "Page not found (404)"
  end

  private
    def sign_in_as_platform_admin
      administrator = create_test_user(email_address: "admin-interface-platform@example.test")
      administrator.update!(system_role: :platform_admin)
      sign_in_as(administrator)
      administrator
    end

    def diagnostic_records
      organization, = create_billing_tenant(prefix: "admin-auth-diagnostic")
      subscription = create_billing_subscription(organization:, plan_price: @plan_price)
      webhook_event = create_billing_webhook_event(
        status: "failed",
        event_name: "admin_auth_failed_event",
        processed_at: 1.second.from_now,
        error_code: "admin_auth_failure"
      )

      [ subscription, webhook_event ]
    end

    def admin_get_paths(subscription:, webhook_event:)
      entitlement = create_test_entitlement(
        plan_product: @plan_product,
        product_feature: @feature
      )

      [
        admin_root_path,
        admin_products_path,
        new_admin_product_path,
        admin_product_path(@product.key),
        edit_admin_product_path(@product.key),
        admin_product_features_path(@product.key),
        new_admin_product_feature_path(@product.key),
        admin_product_feature_path(@product.key, @feature.key),
        edit_admin_product_feature_path(@product.key, @feature.key),
        admin_plans_path,
        new_admin_plan_path,
        admin_plan_path(@plan.key),
        edit_admin_plan_path(@plan.key),
        admin_plan_plan_products_path(@plan.key),
        new_admin_plan_plan_product_path(@plan.key),
        admin_plan_plan_product_path(@plan.key, @product.key),
        admin_plan_feature_entitlements_path(plan_key: @plan.key, product_key: @product.key),
        admin_new_plan_feature_entitlement_path(plan_key: @plan.key, product_key: @product.key),
        admin_plan_feature_entitlement_path(
          plan_key: @plan.key,
          product_key: @product.key,
          feature_key: entitlement.product_feature.key
        ),
        admin_edit_plan_feature_entitlement_path(
          plan_key: @plan.key,
          product_key: @product.key,
          feature_key: entitlement.product_feature.key
        ),
        admin_plan_plan_prices_path(@plan.key),
        new_admin_plan_plan_price_path(@plan.key),
        admin_plan_plan_price_path(@plan.key, @plan_price),
        edit_admin_plan_plan_price_path(@plan.key, @plan_price),
        admin_billing_subscriptions_path,
        admin_billing_subscription_path(
          subscription,
          organization_public_id: subscription.organization.public_id
        ),
        admin_billing_webhook_events_path,
        admin_billing_webhook_event_path(webhook_event)
      ]
    end

    def assert_generic_forbidden
      assert_response :forbidden
      assert_select "title", "Forbidden (403)"
      assert_no_match(/Pundit|NotAuthorized|policy/, response.body)
    end
end
