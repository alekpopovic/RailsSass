require "test_helper"
require_relative "../../support/billing_test_helper"

class Platform::ConfigureProviderPriceMappingTest < ActiveSupport::TestCase
  include BillingTestHelper

  setup do
    @administrator = create_test_user(
      email_address: "mapping-admin-#{SecureRandom.hex(4)}@example.test"
    )
    @administrator.update!(system_role: :platform_admin)
    @plan = create_test_plan(name: "Mapped Professional")
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: "410001",
      lemon_product_id: "420002",
      lemon_variant_id: "430003"
    )
  end

  test "platform admin creates an audited immutable environment mapping" do
    mapping = nil
    assert_difference -> { Billing::ProviderPriceMapping.count }, 1 do
      assert_difference -> { Platform::AuditEvent.where(action: "catalog.created").count }, 1 do
        mapping = configure
      end
    end

    assert_equal @plan_price.id, mapping.plan_price_id
    assert_predicate mapping, :environment_test?
    assert_predicate mapping, :active?
    assert_equal @plan_price.lemon_variant_id, mapping.provider_variant_id
    assert Platform::PersistCatalog.plan_price_referenced?(@plan_price)
    event = Platform::AuditEvent.order(:id).last
    assert_equal "PlanPrice", event.subject_type
    assert_match "/test", event.subject_key
  end

  test "repeated configure is idempotent and deactivation is audited" do
    mapping = configure

    assert_no_difference [
      -> { Billing::ProviderPriceMapping.count },
      -> { Platform::AuditEvent.count }
    ] do
      assert_equal mapping, configure
    end

    assert_difference -> { Platform::AuditEvent.where(action: "catalog.deactivated").count }, 1 do
      mapping = configure(active: false)
    end
    assert_not mapping.active?
  end

  test "ordinary user and inactive or free catalog selections are rejected" do
    ordinary_user = create_test_user(
      email_address: "mapping-ordinary-#{SecureRandom.hex(4)}@example.test"
    )
    assert_raises(Pundit::NotAuthorizedError) do
      described_class.new(
        actor: ordinary_user,
        plan_price: @plan_price,
        environment: "test"
      ).call
    end

    @plan_price.update!(active: false)
    error = assert_raises(ActiveRecord::RecordInvalid) { configure }
    assert_includes error.record.errors[:base], "requires an active paid plan and active price"

    free_plan = create_test_plan(free: true, name: "Mapping Free")
    free_price = create_test_plan_price(
      plan: free_plan,
      lemon_store_id: "440004",
      lemon_product_id: "450005",
      lemon_variant_id: "460006"
    )
    error = assert_raises(ActiveRecord::RecordInvalid) do
      described_class.new(
        actor: @administrator,
        plan_price: free_price,
        environment: "test"
      ).call
    end
    assert_includes error.record.errors[:base], "requires an active paid plan and active price"
  end

  private
    def described_class
      Platform::ConfigureProviderPriceMapping
    end

    def configure(active: true)
      described_class.new(
        actor: @administrator,
        plan_price: @plan_price,
        environment: "test",
        active: active
      ).call
    end
end
