require "test_helper"
require_relative "../support/billing_test_helper"

class CreateBillingCheckoutMappingAndLocatorsTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "mapping and locator tables have required columns checks and unique identities" do
    assert_required_columns(
      Billing::ProviderPriceMapping,
      %w[
        plan_price_id provider environment provider_store_id provider_product_id
        provider_variant_id active created_at updated_at
      ]
    )
    assert_required_columns(
      Billing::ProviderLocator,
      %w[
        organization_id billing_checkout_attempt_id provider environment
        token_digest status created_at updated_at
      ]
    )

    mapping_indexes = Billing::ProviderPriceMapping.connection
      .indexes(:billing_provider_price_mappings)
      .index_by(&:name)
    locator_indexes = Billing::ProviderLocator.connection
      .indexes(:billing_provider_locators)
      .index_by(&:name)
    assert_predicate mapping_indexes.fetch("index_billing_price_mappings_on_local_identity"), :unique
    assert_predicate mapping_indexes.fetch("index_billing_price_mappings_on_provider_identity"), :unique
    assert_predicate locator_indexes.fetch("index_billing_provider_locators_on_checkout_attempt"), :unique
    assert_predicate locator_indexes.fetch("index_billing_provider_locators_on_token_identity"), :unique

    assert_constraint_names(Billing::ProviderPriceMapping, %w[
      billing_price_mappings_provider_allowed
      billing_price_mappings_environment_allowed
      billing_price_mappings_store_id_normalized
      billing_price_mappings_product_id_normalized
      billing_price_mappings_variant_id_normalized
    ])
    assert_constraint_names(Billing::ProviderLocator, %w[
      billing_provider_locators_provider_allowed
      billing_provider_locators_environment_allowed
      billing_provider_locators_token_digest_format
      billing_provider_locators_lifecycle
    ])
  end

  test "composite foreign keys bind mapping attempt locator and tenant identity" do
    mapping_keys = Billing::ProviderPriceMapping.connection.foreign_keys(:billing_provider_price_mappings)
    checkout_keys = Billing::CheckoutAttempt.connection.foreign_keys(:billing_checkout_attempts)
    locator_keys = Billing::ProviderLocator.connection.foreign_keys(:billing_provider_locators)

    assert mapping_keys.any? { |key|
      key.to_table == "plan_prices" &&
        key.column == %w[plan_price_id provider_store_id provider_product_id provider_variant_id]
    }
    assert checkout_keys.any? { |key|
      key.to_table == "billing_provider_price_mappings" &&
        key.column == %w[plan_price_id provider environment] &&
        key.options[:validate] != false
    }
    assert locator_keys.any? { |key|
      key.to_table == "billing_checkout_attempts" &&
        key.column == %w[
          billing_checkout_attempt_id organization_id provider environment token_digest
        ]
    }
    [ Billing::ProviderPriceMapping, Billing::ProviderLocator ].each do |model|
      assert model.connection.foreign_keys(model.table_name).all? { |key| key.on_delete == :restrict }
    end
  end

  test "database rejects unmapped checkout attempts and cross-tenant locators" do
    organization, membership = create_billing_tenant(prefix: "checkout-mapping-db")
    unmapped_price = create_test_plan_price(plan: create_test_plan)
    now = Time.current

    unmapped_error = assert_raises(ActiveRecord::InvalidForeignKey) do
      ApplicationRecord.transaction(requires_new: true) do
        Billing::CheckoutAttempt.insert_all!([ {
          organization_id: organization.id,
          initiated_by_membership_id: membership.id,
          plan_price_id: unmapped_price.id,
          provider: "lemon_squeezy",
          environment: "test",
          test_mode: true,
          token_digest: Digest::SHA256.hexdigest("unmapped-checkout"),
          status: "creating",
          expires_at: now + 30.minutes,
          created_at: now,
          updated_at: now
        } ])
      end
    end
    assert_kind_of PG::ForeignKeyViolation, unmapped_error.cause

    foreign_organization, foreign_membership = create_billing_tenant(prefix: "locator-db-foreign")
    foreign_attempt = create_billing_checkout_attempt(
      organization: foreign_organization,
      membership: foreign_membership
    )
    locator_error = assert_raises(ActiveRecord::InvalidForeignKey) do
      ApplicationRecord.transaction(requires_new: true) do
        Billing::ProviderLocator.insert_all!([ {
          organization_id: organization.id,
          billing_checkout_attempt_id: foreign_attempt.id,
          provider: foreign_attempt.provider,
          environment: foreign_attempt.environment,
          token_digest: foreign_attempt.token_digest,
          status: "unresolved",
          created_at: now,
          updated_at: now
        } ])
      end
    end
    assert_kind_of PG::ForeignKeyViolation, locator_error.cause
  end

  private
    def assert_required_columns(model, names)
      columns = model.columns.index_by(&:name)
      names.each { |name| assert_not columns.fetch(name).null }
    end

    def assert_constraint_names(model, names)
      installed = model.connection.check_constraints(model.table_name).map(&:name)
      names.each { |name| assert_includes installed, name }
    end
end
