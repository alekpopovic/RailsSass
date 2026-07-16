require "test_helper"
require_relative "../support/billing_test_helper"

class AdminProviderPriceMappingsRequestTest < ActionDispatch::IntegrationTest
  include BillingTestHelper

  setup do
    @administrator = create_test_user(
      email_address: "admin-mapping-#{SecureRandom.hex(4)}@example.test"
    )
    @administrator.update!(system_role: :platform_admin)
    @plan = create_test_plan(key: unique_catalog_key("admin_mapping_plan"))
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: "310001",
      lemon_product_id: "320002",
      lemon_variant_id: "330003"
    )
    sign_in_as(@administrator)
  end

  test "platform admin configures and deactivates a visible test-mode mapping" do
    get admin_plan_plan_price_path(@plan.key, @plan_price)
    assert_response :success
    assert_match(/no test\/live checkout mapping/i, response.body)

    get new_admin_plan_plan_price_provider_price_mapping_path(@plan.key, @plan_price)
    assert_response :success
    assert_select "select[name='billing_provider_price_mapping[environment]']"

    assert_difference -> { Billing::ProviderPriceMapping.count }, 1 do
      post admin_plan_plan_price_provider_price_mappings_path(@plan.key, @plan_price),
        params: {
          billing_provider_price_mapping: {
            environment: "test",
            active: "1",
            provider_store_id: "attacker-store"
          }
        }
    end
    assert_redirected_to admin_plan_plan_price_path(@plan.key, @plan_price)

    get admin_plan_plan_price_path(@plan.key, @plan_price)
    assert_response :success
    assert_match "Test mode", response.body
    assert_no_match(/synthetic-api-key|webhook secret/i, response.body)
    mapping = @plan_price.billing_provider_price_mappings.find_by!(environment: "test")
    assert_equal @plan_price.lemon_store_id, mapping.provider_store_id

    patch admin_plan_plan_price_provider_price_mapping_path(
      @plan.key,
      @plan_price,
      mapping.environment
    ), params: {
      billing_provider_price_mapping: {
        environment: "live",
        active: "0"
      }
    }
    assert_redirected_to admin_plan_plan_price_path(@plan.key, @plan_price)
    assert_not mapping.reload.active?
    assert_predicate mapping, :environment_test?
  end

  test "ordinary user cannot render or mutate provider mappings" do
    delete session_path
    ordinary_user = create_test_user(
      email_address: "ordinary-mapping-#{SecureRandom.hex(4)}@example.test"
    )
    sign_in_as(ordinary_user)

    get new_admin_plan_plan_price_provider_price_mapping_path(@plan.key, @plan_price)
    assert_response :forbidden

    assert_no_difference -> { Billing::ProviderPriceMapping.count } do
      post admin_plan_plan_price_provider_price_mappings_path(@plan.key, @plan_price),
        params: {
          billing_provider_price_mapping: { environment: "test", active: "1" }
        }
    end
    assert_response :forbidden
  end
end
