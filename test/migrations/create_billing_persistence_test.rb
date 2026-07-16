require "test_helper"
require_relative "../support/billing_test_helper"

class CreateBillingPersistenceTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "billing tables install required columns and named checks" do
    assert_required_columns(
      Billing::Customer,
      %w[organization_id provider environment provider_customer_id test_mode created_at updated_at]
    )
    assert_required_columns(
      Billing::CheckoutAttempt,
      %w[
        organization_id initiated_by_membership_id plan_price_id provider environment
        test_mode token_digest status expires_at created_at updated_at
      ]
    )
    assert_required_columns(
      Billing::Subscription,
      %w[
        organization_id billing_customer_id plan_price_id provider environment
        provider_subscription_id provider_customer_id status current provider_updated_at
        pause test_mode raw_payload lock_version created_at updated_at
      ]
    )
    assert Billing::Subscription.columns_hash.key?("past_due_started_at")
    assert_predicate Billing::Subscription.columns_hash.fetch("past_due_started_at"), :null
    assert_required_columns(
      Billing::WebhookEvent,
      %w[
        provider environment fingerprint status received_at verified_at attempt_count
        snapshot created_at updated_at
      ]
    )
    assert_required_columns(
      Billing::PlanChange,
      %w[
        organization_id billing_subscription_id requested_by_membership_id
        from_plan_price_id to_plan_price_id provider environment test_mode status
        requested_at created_at updated_at
      ]
    )

    assert_constraint_names(Billing::Subscription, %w[
      billing_subscriptions_environment_test_mode_consistent
      billing_subscriptions_status_allowed
      billing_subscriptions_current_archive_consistent
      billing_subscriptions_trial_end_required
      billing_subscriptions_cancelled_end_required
      billing_subscriptions_past_due_cycle_consistent
      billing_subscriptions_pause_object_bounded
      billing_subscriptions_raw_payload_object_bounded
      billing_subscriptions_card_display_consistent
    ])
    assert_constraint_names(Billing::WebhookEvent, %w[
      billing_webhook_events_fingerprint_format
      billing_webhook_events_lifecycle
      billing_webhook_events_snapshot_object_bounded
    ])
    past_due_constraint = Billing::Subscription.connection
      .check_constraints(:billing_subscriptions)
      .find { |constraint| constraint.name == "billing_subscriptions_past_due_cycle_consistent" }
    assert_equal false, past_due_constraint.options.fetch(:validate)
  end

  test "indexes enforce provider identities one current subscription and pending commands" do
    provider_identity = index_for(
      Billing::Subscription,
      "index_billing_subscriptions_on_provider_identity"
    )
    current = index_for(
      Billing::Subscription,
      "index_billing_subscriptions_on_one_current_per_org"
    )
    pending_checkout = index_for(
      Billing::CheckoutAttempt,
      "index_billing_checkout_attempts_on_one_pending_per_org"
    )
    pending_change = index_for(
      Billing::PlanChange,
      "index_billing_plan_changes_on_one_pending_per_subscription"
    )
    history = index_for(
      Billing::PlanChange,
      "index_billing_plan_changes_on_subscription_history"
    )

    [ provider_identity, current, pending_checkout, pending_change ].each do |index|
      assert_predicate index, :unique
    end
    assert_equal %w[provider environment provider_subscription_id], provider_identity.columns
    assert_match(/current/i, current.where)
    assert_match(/creation_unknown/i, pending_checkout.where)
    assert_match(/creation_unknown/i, pending_change.where)
    assert_equal %w[billing_subscription_id requested_at], history.columns
  end

  test "all billing foreign keys restrict deletion and composite keys enforce tenant identity" do
    billing_models.each do |model|
      assert model.connection.foreign_keys(model.table_name).all? { |foreign_key|
        foreign_key.on_delete == :restrict
      }, "expected every #{model.table_name} foreign key to restrict deletion"
    end

    subscription_keys = Billing::Subscription.connection.foreign_keys(:billing_subscriptions)
    assert subscription_keys.any? { |foreign_key|
      foreign_key.to_table == "billing_customers" &&
        foreign_key.column == %w[
          billing_customer_id organization_id provider environment test_mode provider_customer_id
        ]
    }

    checkout_keys = Billing::CheckoutAttempt.connection.foreign_keys(:billing_checkout_attempts)
    assert checkout_keys.any? { |foreign_key|
      foreign_key.to_table == "organization_memberships" &&
        foreign_key.column == %w[initiated_by_membership_id organization_id] &&
        foreign_key.primary_key == %w[id organization_id]
    }

    plan_change_keys = Billing::PlanChange.connection.foreign_keys(:billing_plan_changes)
    assert plan_change_keys.any? { |foreign_key|
      foreign_key.to_table == "billing_subscriptions" &&
        foreign_key.column == %w[
          billing_subscription_id organization_id provider environment test_mode
        ]
    }
  end

  test "database permits archived history but rejects a second current subscription" do
    organization, = create_billing_tenant(prefix: "db-current")
    customer = create_billing_customer(organization: organization)
    archived = create_billing_subscription(
      organization: organization,
      billing_customer: customer
    )
    archived.update!(current: false, archived_at: Time.current)
    create_billing_subscription(organization: organization, billing_customer: customer)

    error = assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      Billing::Subscription.insert_all!([ raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_second_current"
      ) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
    assert_equal 2, organization.billing_subscriptions.count
    assert_equal 1, organization.billing_subscriptions.where(current: true).count
  end

  test "database rejects duplicate environment-qualified provider subscription identities" do
    first_organization, = create_billing_tenant(prefix: "provider-id-first")
    first = create_billing_subscription(
      organization: first_organization,
      provider_subscription_id: "subscription_provider_unique"
    )
    second_organization, = create_billing_tenant(prefix: "provider-id-second")
    second_customer = create_billing_customer(organization: second_organization)

    error = assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      Billing::Subscription.insert_all!([ raw_subscription_attributes(
        organization: second_organization,
        customer: second_customer,
        provider_subscription_id: first.provider_subscription_id
      ) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database rejects cross-tenant customer and membership relationships" do
    organization, = create_billing_tenant(prefix: "db-local")
    foreign_organization, foreign_membership = create_billing_tenant(prefix: "db-foreign")
    foreign_customer = create_billing_customer(organization: foreign_organization)

    subscription_error = assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      Billing::Subscription.insert_all!([ raw_subscription_attributes(
        organization: organization,
        customer: foreign_customer,
        provider_subscription_id: "subscription_cross_tenant_db"
      ) ])
    end
    checkout_error = assert_database_error(ActiveRecord::InvalidForeignKey, PG::ForeignKeyViolation) do
      Billing::CheckoutAttempt.insert_all!([ raw_checkout_attributes(
        organization: organization,
        membership: foreign_membership
      ) ])
    end

    assert_kind_of PG::ForeignKeyViolation, subscription_error.cause
    assert_kind_of PG::ForeignKeyViolation, checkout_error.cause
  end

  test "database rejects malformed lifecycle environment JSON and card state" do
    organization, = create_billing_tenant(prefix: "db-checks")
    customer = create_billing_customer(organization: organization)

    invalid_rows = [
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_live_test_mode",
        environment: "live",
        test_mode: true
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_unarchived_history",
        current: false,
        archived_at: nil
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_missing_trial_end",
        status: "on_trial"
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_missing_past_due_start",
        status: "past_due"
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_stale_past_due_start",
        status: "active",
        past_due_started_at: Time.current
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_future_past_due_start",
        status: "past_due",
        past_due_started_at: 1.hour.from_now
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_array_payload",
        raw_payload: [ "not", "an", "object" ]
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_oversized_payload",
        raw_payload: { "status" => SecureRandom.alphanumeric(70_000) }
      ),
      raw_subscription_attributes(
        organization: organization,
        customer: customer,
        provider_subscription_id: "subscription_partial_card",
        card_brand: "visa",
        card_last_four: nil
      )
    ]

    invalid_rows.each do |attributes|
      error = assert_database_error(
        ActiveRecord::StatementInvalid,
        PG::CheckViolation
      ) do
        Billing::Subscription.insert_all!([ attributes ])
      end
      assert_kind_of PG::CheckViolation, error.cause
    end
  end

  test "webhook fingerprint and pending operation indexes are idempotency guards" do
    event = create_billing_webhook_event(provider_event_id: "provider_event_unique")
    duplicate_event_error = assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      Billing::WebhookEvent.insert_all!([ raw_webhook_attributes(fingerprint: event.fingerprint) ])
    end
    assert_kind_of PG::UniqueViolation, duplicate_event_error.cause

    duplicate_provider_event_error = assert_database_error(
      ActiveRecord::RecordNotUnique,
      PG::UniqueViolation
    ) do
      Billing::WebhookEvent.insert_all!([ raw_webhook_attributes(
        fingerprint: Digest::SHA256.hexdigest("different-provider-event-body"),
        provider_event_id: event.provider_event_id
      ) ])
    end
    assert_kind_of PG::UniqueViolation, duplicate_provider_event_error.cause

    organization, membership = create_billing_tenant(prefix: "db-pending")
    attempt = create_billing_checkout_attempt(organization: organization, membership: membership)
    duplicate_attempt_error = assert_database_error(ActiveRecord::RecordNotUnique, PG::UniqueViolation) do
      Billing::CheckoutAttempt.insert_all!([ raw_checkout_attributes(
        organization: organization,
        membership: membership,
        token_digest: Digest::SHA256.hexdigest("other-pending-attempt")
      ) ])
    end
    assert_kind_of PG::UniqueViolation, duplicate_attempt_error.cause
    assert_predicate attempt, :status_creating?
  end

  test "database makes archived subscription state one way and prevents history deletion" do
    organization, = create_billing_tenant(prefix: "db-history-trigger")
    subscription = create_billing_subscription(organization: organization)
    subscription.update!(current: false, archived_at: Time.current)

    update_error = assert_database_error(ActiveRecord::StatementInvalid, PG::CheckViolation) do
      Billing::Subscription.where(id: subscription.id).update_all(current: true, archived_at: nil)
    end
    delete_error = assert_database_error(
      ActiveRecord::StatementInvalid,
      PG::ObjectNotInPrerequisiteState
    ) do
      Billing::Subscription.where(id: subscription.id).delete_all
    end

    assert_kind_of PG::CheckViolation, update_error.cause
    assert_kind_of PG::ObjectNotInPrerequisiteState, delete_error.cause
    assert_predicate subscription.reload, :persisted?
  end

  private
    def billing_models
      [
        Billing::Customer,
        Billing::CheckoutAttempt,
        Billing::Subscription,
        Billing::WebhookEvent,
        Billing::PlanChange
      ]
    end

    def assert_required_columns(model, names)
      columns = model.columns.index_by(&:name)
      names.each do |name|
        assert_not columns.fetch(name).null, "expected #{model.table_name}.#{name} to be NOT NULL"
      end
    end

    def assert_constraint_names(model, names)
      installed_names = model.connection.check_constraints(model.table_name).map(&:name)
      names.each { |name| assert_includes installed_names, name }
    end

    def index_for(model, name)
      model.connection.indexes(model.table_name).index_by(&:name).fetch(name)
    end

    def assert_database_error(exception_class, cause_class, &block)
      error = assert_raises(exception_class) do
        ApplicationRecord.transaction(requires_new: true, &block)
      end
      assert_kind_of cause_class, error.cause
      error
    end

    def raw_subscription_attributes(organization:, customer:, provider_subscription_id:, **overrides)
      now = Time.current
      {
        organization_id: organization.id,
        billing_customer_id: customer.id,
        plan_price_id: create_test_plan_price(plan: create_test_plan).id,
        provider: "lemon_squeezy",
        environment: customer.environment,
        provider_subscription_id: provider_subscription_id,
        provider_customer_id: customer.provider_customer_id,
        status: "active",
        current: true,
        provider_updated_at: now,
        pause: {},
        test_mode: customer.test_mode,
        raw_payload: {},
        archived_at: nil,
        lock_version: 0,
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def raw_checkout_attributes(organization:, membership:, **overrides)
      now = Time.current
      {
        organization_id: organization.id,
        initiated_by_membership_id: membership.id,
        plan_price_id: create_test_plan_price(plan: create_test_plan).id,
        provider: "lemon_squeezy",
        environment: "test",
        test_mode: true,
        token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(32)),
        status: "creating",
        expires_at: now + 30.minutes,
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def raw_webhook_attributes(fingerprint:, **overrides)
      now = Time.current
      {
        provider: "lemon_squeezy",
        environment: "test",
        fingerprint: fingerprint,
        status: "received",
        test_mode: true,
        received_at: now,
        verified_at: now,
        attempt_count: 0,
        snapshot: {},
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end
end
