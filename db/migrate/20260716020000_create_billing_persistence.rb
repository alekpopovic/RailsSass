class CreateBillingPersistence < ActiveRecord::Migration[8.1]
  def change
    create_billing_customers
    create_billing_checkout_attempts
    create_billing_subscriptions
    create_billing_webhook_events
    create_billing_plan_changes
  end

  private
    def create_billing_customers
      create_table :billing_customers do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.string :provider_customer_id, null: false, limit: 128
        t.boolean :test_mode, null: false
        t.datetime :provider_updated_at

        t.timestamps null: false
      end

      add_index :billing_customers,
        [ :provider, :environment, :provider_customer_id ],
        unique: true,
        name: "index_billing_customers_on_provider_identity"
      add_index :billing_customers,
        [ :id, :organization_id, :provider, :environment, :test_mode, :provider_customer_id ],
        unique: true,
        name: "index_billing_customers_on_subscription_identity"
      add_index :billing_customers,
        [ :organization_id, :provider, :environment ],
        name: "index_billing_customers_on_org_provider_environment"

      add_provider_constraints(:billing_customers)
      add_provider_identifier_constraint(
        :billing_customers,
        :provider_customer_id,
        "billing_customers_provider_customer_id_normalized"
      )
    end

    def create_billing_checkout_attempts
      create_table :billing_checkout_attempts do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.bigint :initiated_by_membership_id, null: false
        t.references :plan_price,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.boolean :test_mode, null: false
        t.string :token_digest, null: false, limit: 64
        t.string :status, null: false, default: "creating", limit: 32
        t.string :provider_checkout_id, limit: 128
        t.datetime :expires_at, null: false
        t.datetime :token_consumed_at
        t.datetime :completed_at
        t.string :failure_code, limit: 64

        t.timestamps null: false
      end

      add_index :billing_checkout_attempts, :initiated_by_membership_id,
        name: "index_billing_checkout_attempts_on_membership"
      add_index :billing_checkout_attempts, :token_digest, unique: true
      add_index :billing_checkout_attempts,
        [ :provider, :environment, :provider_checkout_id ],
        unique: true,
        where: "provider_checkout_id IS NOT NULL",
        name: "index_billing_checkout_attempts_on_provider_identity"
      add_index :billing_checkout_attempts,
        [ :organization_id, :status, :expires_at ],
        name: "index_billing_checkout_attempts_on_org_status_expiry"
      add_index :billing_checkout_attempts,
        :organization_id,
        unique: true,
        where: "status IN ('creating', 'ready', 'creation_unknown')",
        name: "index_billing_checkout_attempts_on_one_pending_per_org"
      add_index :billing_checkout_attempts,
        [ :id, :organization_id, :plan_price_id, :provider, :environment ],
        unique: true,
        name: "index_billing_checkout_attempts_on_origin_identity"
      add_index :billing_checkout_attempts,
        [ :id, :organization_id, :provider, :environment, :token_digest ],
        unique: true,
        name: "index_billing_checkout_attempts_on_locator_identity"

      add_foreign_key :billing_checkout_attempts,
        :organization_memberships,
        column: [ :initiated_by_membership_id, :organization_id ],
        primary_key: [ :id, :organization_id ],
        on_delete: :restrict,
        name: "fk_billing_checkout_attempts_membership_tenant"

      add_provider_constraints(:billing_checkout_attempts)
      add_provider_identifier_constraint(
        :billing_checkout_attempts,
        :provider_checkout_id,
        "billing_checkout_attempts_provider_id_normalized",
        nullable: true
      )
      add_check_constraint :billing_checkout_attempts,
        "token_digest ~ '^[0-9a-f]{64}$'",
        name: "billing_checkout_attempts_token_digest_format"
      add_check_constraint :billing_checkout_attempts,
        <<~SQL.squish,
          status IN (
            'creating', 'ready', 'creation_unknown', 'completed',
            'expired', 'superseded', 'failed'
          )
        SQL
        name: "billing_checkout_attempts_status_allowed"
      add_check_constraint :billing_checkout_attempts,
        <<~SQL.squish,
          (
            status IN ('creating', 'creation_unknown')
            AND completed_at IS NULL
            AND token_consumed_at IS NULL
            AND failure_code IS NULL
          ) OR (
            status = 'ready'
            AND provider_checkout_id IS NOT NULL
            AND completed_at IS NULL
            AND token_consumed_at IS NULL
            AND failure_code IS NULL
          ) OR (
            status = 'completed'
            AND provider_checkout_id IS NOT NULL
            AND completed_at IS NOT NULL
            AND token_consumed_at IS NOT NULL
            AND failure_code IS NULL
          ) OR (
            status IN ('expired', 'superseded')
            AND completed_at IS NOT NULL
            AND token_consumed_at IS NULL
            AND failure_code IS NULL
          ) OR (
            status = 'failed'
            AND completed_at IS NOT NULL
            AND token_consumed_at IS NULL
            AND failure_code IS NOT NULL
          )
        SQL
        name: "billing_checkout_attempts_lifecycle"
      add_check_constraint :billing_checkout_attempts,
        "expires_at > created_at",
        name: "billing_checkout_attempts_expiry_after_creation"
      add_check_constraint :billing_checkout_attempts,
        "completed_at IS NULL OR completed_at >= created_at",
        name: "billing_checkout_attempts_completed_after_creation"
      add_check_constraint :billing_checkout_attempts,
        "token_consumed_at IS NULL OR " \
          "(token_consumed_at >= created_at AND token_consumed_at <= completed_at)",
        name: "billing_checkout_attempts_token_consumed_at_valid"
      add_optional_code_constraint(
        :billing_checkout_attempts,
        :failure_code,
        "billing_checkout_attempts_failure_code_normalized"
      )
    end

    def create_billing_subscriptions
      create_table :billing_subscriptions do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :billing_customer,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :plan_price,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.string :provider_subscription_id, null: false, limit: 128
        t.string :provider_customer_id, null: false, limit: 128
        t.string :status, null: false, limit: 32
        t.boolean :current, null: false, default: true
        t.datetime :trial_ends_at
        t.datetime :renews_at
        t.datetime :ends_at
        t.datetime :provider_updated_at, null: false
        t.jsonb :pause, null: false, default: {}
        t.string :card_brand, limit: 32
        t.string :card_last_four, limit: 4
        t.boolean :test_mode, null: false
        t.jsonb :raw_payload, null: false, default: {}
        t.datetime :archived_at
        t.bigint :lock_version, null: false, default: 0

        t.timestamps null: false
      end

      add_index :billing_subscriptions,
        [ :provider, :environment, :provider_subscription_id ],
        unique: true,
        name: "index_billing_subscriptions_on_provider_identity"
      add_index :billing_subscriptions,
        :organization_id,
        unique: true,
        where: "current",
        name: "index_billing_subscriptions_on_one_current_per_org"
      add_index :billing_subscriptions, :status
      add_index :billing_subscriptions,
        [ :organization_id, :status ],
        name: "index_billing_subscriptions_on_org_and_status"
      add_index :billing_subscriptions,
        [ :provider, :environment, :provider_customer_id ],
        name: "index_billing_subscriptions_on_provider_customer"
      add_index :billing_subscriptions,
        [ :provider, :environment, :provider_updated_at ],
        name: "index_billing_subscriptions_on_provider_updated_at"
      add_index :billing_subscriptions,
        [ :id, :organization_id, :provider, :environment, :test_mode ],
        unique: true,
        name: "index_billing_subscriptions_on_plan_change_identity"
      add_index :billing_subscriptions,
        [ :id, :organization_id, :provider, :environment, :provider_subscription_id ],
        unique: true,
        name: "index_billing_subscriptions_on_locator_identity"

      add_foreign_key :billing_subscriptions,
        :billing_customers,
        column: [
          :billing_customer_id,
          :organization_id,
          :provider,
          :environment,
          :test_mode,
          :provider_customer_id
        ],
        primary_key: [
          :id,
          :organization_id,
          :provider,
          :environment,
          :test_mode,
          :provider_customer_id
        ],
        on_delete: :restrict,
        name: "fk_billing_subscriptions_customer_identity"

      add_provider_constraints(:billing_subscriptions)
      add_provider_identifier_constraint(
        :billing_subscriptions,
        :provider_subscription_id,
        "billing_subscriptions_provider_subscription_id_normalized"
      )
      add_provider_identifier_constraint(
        :billing_subscriptions,
        :provider_customer_id,
        "billing_subscriptions_provider_customer_id_normalized"
      )
      add_check_constraint :billing_subscriptions,
        <<~SQL.squish,
          status IN (
            'on_trial', 'active', 'paused', 'past_due', 'unpaid',
            'cancelled', 'expired', 'unknown'
          )
        SQL
        name: "billing_subscriptions_status_allowed"
      add_check_constraint :billing_subscriptions,
        "(current AND archived_at IS NULL) OR (NOT current AND archived_at IS NOT NULL)",
        name: "billing_subscriptions_current_archive_consistent"
      add_check_constraint :billing_subscriptions,
        "archived_at IS NULL OR archived_at >= created_at",
        name: "billing_subscriptions_archive_after_creation"
      add_check_constraint :billing_subscriptions,
        "status <> 'on_trial' OR trial_ends_at IS NOT NULL",
        name: "billing_subscriptions_trial_end_required"
      add_check_constraint :billing_subscriptions,
        "status <> 'cancelled' OR ends_at IS NOT NULL",
        name: "billing_subscriptions_cancelled_end_required"
      add_check_constraint :billing_subscriptions,
        "jsonb_typeof(pause) = 'object' AND pg_column_size(pause) <= 65536",
        name: "billing_subscriptions_pause_object_bounded"
      add_check_constraint :billing_subscriptions,
        "jsonb_typeof(raw_payload) = 'object' AND pg_column_size(raw_payload) <= 65536",
        name: "billing_subscriptions_raw_payload_object_bounded"
      add_check_constraint :billing_subscriptions,
        <<~SQL.squish,
          (
            card_brand IS NULL
            AND card_last_four IS NULL
          ) OR (
            card_brand IS NOT NULL
            AND card_brand = btrim(card_brand)
            AND char_length(card_brand) BETWEEN 1 AND 32
            AND card_last_four IS NOT NULL
            AND card_last_four ~ '^[0-9]{4}$'
          )
        SQL
        name: "billing_subscriptions_card_display_consistent"
      add_check_constraint :billing_subscriptions,
        "lock_version >= 0",
        name: "billing_subscriptions_lock_version_non_negative"

      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION public.protect_billing_subscription_history()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, public
            AS $function$
            BEGIN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'billing subscription history must be archived, not deleted'
                  USING ERRCODE = '55000',
                    TABLE = 'billing_subscriptions';
              END IF;

              IF OLD.current = FALSE AND (
                NEW.current <> FALSE
                OR NEW.archived_at IS DISTINCT FROM OLD.archived_at
              ) THEN
                RAISE EXCEPTION 'archived billing subscription state is immutable'
                  USING ERRCODE = '23514',
                    CONSTRAINT = 'billing_subscriptions_archive_is_one_way',
                    TABLE = 'billing_subscriptions';
              END IF;

              RETURN NEW;
            END;
            $function$;

            CREATE TRIGGER billing_subscription_history_is_preserved
            BEFORE UPDATE OR DELETE ON billing_subscriptions
            FOR EACH ROW
            EXECUTE FUNCTION public.protect_billing_subscription_history();
          SQL
        end

        direction.down do
          execute <<~SQL
            DROP TRIGGER IF EXISTS billing_subscription_history_is_preserved
              ON billing_subscriptions;
            DROP FUNCTION IF EXISTS public.protect_billing_subscription_history();
          SQL
        end
      end
    end

    def create_billing_webhook_events
      create_table :billing_webhook_events do |t|
        t.references :organization,
          null: true,
          foreign_key: { on_delete: :restrict }
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.string :fingerprint, null: false, limit: 64
        t.string :provider_event_id, limit: 128
        t.string :event_name, limit: 100
        t.string :provider_resource_id, limit: 128
        t.string :status, null: false, default: "received", limit: 32
        t.boolean :test_mode
        t.datetime :received_at, null: false
        t.datetime :verified_at, null: false
        t.datetime :processed_at
        t.datetime :provider_updated_at
        t.integer :attempt_count, null: false, default: 0
        t.string :error_code, limit: 64
        t.jsonb :snapshot, null: false, default: {}

        t.timestamps null: false
      end

      add_index :billing_webhook_events, :fingerprint, unique: true
      add_index :billing_webhook_events,
        [ :provider, :environment, :provider_event_id ],
        unique: true,
        where: "provider_event_id IS NOT NULL",
        name: "index_billing_webhook_events_on_provider_event_identity"
      add_index :billing_webhook_events,
        [ :status, :received_at ],
        name: "index_billing_webhook_events_on_status_and_received"
      add_index :billing_webhook_events,
        [ :provider, :environment, :provider_resource_id ],
        name: "index_billing_webhook_events_on_provider_resource"

      add_check_constraint :billing_webhook_events,
        "provider = 'lemon_squeezy'",
        name: "billing_webhook_events_provider_allowed"
      add_check_constraint :billing_webhook_events,
        "environment IN ('test', 'live')",
        name: "billing_webhook_events_environment_allowed"
      add_check_constraint :billing_webhook_events,
        <<~SQL.squish,
          test_mode IS NULL OR
          (environment = 'test' AND test_mode = TRUE) OR
          (environment = 'live' AND test_mode = FALSE)
        SQL
        name: "billing_webhook_events_environment_test_mode_consistent"
      add_check_constraint :billing_webhook_events,
        "fingerprint ~ '^[0-9a-f]{64}$'",
        name: "billing_webhook_events_fingerprint_format"
      add_check_constraint :billing_webhook_events,
        <<~SQL.squish,
          status IN (
            'received', 'processing', 'processed', 'ignored',
            'quarantined', 'failed'
          )
        SQL
        name: "billing_webhook_events_status_allowed"
      add_check_constraint :billing_webhook_events,
        <<~SQL.squish,
          (
            status IN ('received', 'processing')
            AND processed_at IS NULL
            AND error_code IS NULL
          ) OR (
            status IN ('processed', 'ignored')
            AND processed_at IS NOT NULL
            AND error_code IS NULL
          ) OR (
            status IN ('quarantined', 'failed')
            AND processed_at IS NOT NULL
            AND error_code IS NOT NULL
          )
        SQL
        name: "billing_webhook_events_lifecycle"
      add_check_constraint :billing_webhook_events,
        "attempt_count >= 0",
        name: "billing_webhook_events_attempt_count_non_negative"
      add_check_constraint :billing_webhook_events,
        "verified_at >= received_at",
        name: "billing_webhook_events_verified_after_received"
      add_check_constraint :billing_webhook_events,
        "processed_at IS NULL OR processed_at >= verified_at",
        name: "billing_webhook_events_processed_after_verified"
      add_check_constraint :billing_webhook_events,
        "event_name IS NULL OR " \
          "(event_name = btrim(event_name) AND char_length(event_name) BETWEEN 1 AND 100)",
        name: "billing_webhook_events_event_name_normalized"
      add_provider_identifier_constraint(
        :billing_webhook_events,
        :provider_event_id,
        "billing_webhook_events_provider_event_id_normalized",
        nullable: true
      )
      add_provider_identifier_constraint(
        :billing_webhook_events,
        :provider_resource_id,
        "billing_webhook_events_resource_id_normalized",
        nullable: true
      )
      add_optional_code_constraint(
        :billing_webhook_events,
        :error_code,
        "billing_webhook_events_error_code_normalized"
      )
      add_check_constraint :billing_webhook_events,
        "jsonb_typeof(snapshot) = 'object' AND pg_column_size(snapshot) <= 65536",
        name: "billing_webhook_events_snapshot_object_bounded"
    end

    def create_billing_plan_changes
      create_table :billing_plan_changes do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.bigint :billing_subscription_id, null: false
        t.bigint :requested_by_membership_id, null: false
        t.bigint :from_plan_price_id, null: false
        t.bigint :to_plan_price_id, null: false
        t.string :provider, null: false, default: "lemon_squeezy", limit: 32
        t.string :environment, null: false, limit: 8
        t.boolean :test_mode, null: false
        t.string :status, null: false, default: "pending", limit: 32
        t.datetime :requested_at, null: false
        t.datetime :provider_updated_at
        t.datetime :completed_at
        t.string :failure_code, limit: 64

        t.timestamps null: false
      end

      add_index :billing_plan_changes, :requested_by_membership_id,
        name: "index_billing_plan_changes_on_membership"
      add_index :billing_plan_changes,
        [ :billing_subscription_id, :requested_at ],
        name: "index_billing_plan_changes_on_subscription_history"
      add_index :billing_plan_changes, :from_plan_price_id
      add_index :billing_plan_changes, :to_plan_price_id
      add_index :billing_plan_changes,
        [ :organization_id, :status, :requested_at ],
        name: "index_billing_plan_changes_on_org_status_requested"
      add_index :billing_plan_changes,
        :billing_subscription_id,
        unique: true,
        where: "status IN ('pending', 'submitted', 'creation_unknown')",
        name: "index_billing_plan_changes_on_one_pending_per_subscription"

      add_foreign_key :billing_plan_changes,
        :billing_subscriptions,
        column: [
          :billing_subscription_id,
          :organization_id,
          :provider,
          :environment,
          :test_mode
        ],
        primary_key: [ :id, :organization_id, :provider, :environment, :test_mode ],
        on_delete: :restrict,
        name: "fk_billing_plan_changes_subscription_tenant"
      add_foreign_key :billing_plan_changes,
        :organization_memberships,
        column: [ :requested_by_membership_id, :organization_id ],
        primary_key: [ :id, :organization_id ],
        on_delete: :restrict,
        name: "fk_billing_plan_changes_membership_tenant"
      add_foreign_key :billing_plan_changes,
        :plan_prices,
        column: :from_plan_price_id,
        on_delete: :restrict,
        name: "fk_billing_plan_changes_from_plan_price"
      add_foreign_key :billing_plan_changes,
        :plan_prices,
        column: :to_plan_price_id,
        on_delete: :restrict,
        name: "fk_billing_plan_changes_to_plan_price"

      add_provider_constraints(:billing_plan_changes)
      add_check_constraint :billing_plan_changes,
        "from_plan_price_id <> to_plan_price_id",
        name: "billing_plan_changes_prices_differ"
      add_check_constraint :billing_plan_changes,
        <<~SQL.squish,
          status IN (
            'pending', 'submitted', 'creation_unknown',
            'applied', 'failed', 'superseded'
          )
        SQL
        name: "billing_plan_changes_status_allowed"
      add_check_constraint :billing_plan_changes,
        <<~SQL.squish,
          (
            status IN ('pending', 'submitted', 'creation_unknown')
            AND completed_at IS NULL
            AND failure_code IS NULL
          ) OR (
            status IN ('applied', 'superseded')
            AND completed_at IS NOT NULL
            AND failure_code IS NULL
          ) OR (
            status = 'failed'
            AND completed_at IS NOT NULL
            AND failure_code IS NOT NULL
          )
        SQL
        name: "billing_plan_changes_lifecycle"
      add_check_constraint :billing_plan_changes,
        "completed_at IS NULL OR completed_at >= requested_at",
        name: "billing_plan_changes_completed_after_requested"
      add_optional_code_constraint(
        :billing_plan_changes,
        :failure_code,
        "billing_plan_changes_failure_code_normalized"
      )
    end

    def add_provider_constraints(table_name)
      add_check_constraint table_name,
        "provider = 'lemon_squeezy'",
        name: "#{table_name}_provider_allowed"
      add_check_constraint table_name,
        "environment IN ('test', 'live')",
        name: "#{table_name}_environment_allowed"
      add_check_constraint table_name,
        <<~SQL.squish,
          (environment = 'test' AND test_mode = TRUE) OR
          (environment = 'live' AND test_mode = FALSE)
        SQL
        name: "#{table_name}_environment_test_mode_consistent"
    end

    def add_provider_identifier_constraint(table_name, column_name, constraint_name, nullable: false)
      expression = <<~SQL.squish
        #{column_name} = btrim(#{column_name})
        AND #{column_name} !~ '[[:space:]]'
        AND char_length(#{column_name}) BETWEEN 1 AND 128
      SQL
      expression = "#{column_name} IS NULL OR (#{expression})" if nullable

      add_check_constraint table_name, expression, name: constraint_name
    end

    def add_optional_code_constraint(table_name, column_name, constraint_name)
      add_check_constraint table_name,
        <<~SQL.squish,
          #{column_name} IS NULL OR (
            #{column_name} = btrim(#{column_name})
            AND #{column_name} ~ '^[a-z][a-z0-9_]*$'
            AND char_length(#{column_name}) BETWEEN 1 AND 64
          )
        SQL
        name: constraint_name
    end
end
