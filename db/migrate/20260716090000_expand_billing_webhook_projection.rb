class ExpandBillingWebhookProjection < ActiveRecord::Migration[8.1]
  def up
    mark_verified_webhook_ingress
    expand_subscriptions
    expand_provider_locators
    relax_completed_checkout_lifecycle
  end

  def down
    restore_completed_checkout_lifecycle
    contract_provider_locators
    contract_subscriptions
    remove_verified_webhook_ingress_marker
  end

  private
    def mark_verified_webhook_ingress
      add_column :billing_webhook_events, :ingress_version, :integer
      add_index :billing_webhook_events,
        [ :status, :ingress_version, :received_at ],
        name: "index_billing_webhook_events_on_verified_recovery"
      add_check_constraint :billing_webhook_events,
        "ingress_version IS NULL OR ingress_version = 1",
        name: "billing_webhook_events_ingress_version_allowed"
    end

    def expand_subscriptions
      add_column :billing_subscriptions, :last_seen_provider_updated_at, :datetime
      add_column :billing_subscriptions,
        :sync_state,
        :string,
        null: false,
        default: "synced",
        limit: 32
      add_column :billing_subscriptions, :origin_plan_price_id, :bigint
      add_column :billing_subscriptions, :origin_checkout_attempt_id, :bigint

      execute <<~SQL.squish
        UPDATE billing_subscriptions
        SET last_seen_provider_updated_at = provider_updated_at,
            origin_plan_price_id = plan_price_id
      SQL

      change_column_null :billing_subscriptions, :last_seen_provider_updated_at, false
      change_column_null :billing_subscriptions, :origin_plan_price_id, false

      add_index :billing_subscriptions,
        :origin_plan_price_id,
        name: "index_billing_subscriptions_on_origin_plan_price"
      add_index :billing_subscriptions,
        :origin_checkout_attempt_id,
        unique: true,
        where: "origin_checkout_attempt_id IS NOT NULL",
        name: "index_billing_subscriptions_on_origin_checkout_attempt"
      add_index :billing_subscriptions,
        [ :sync_state, :last_seen_provider_updated_at ],
        name: "index_billing_subscriptions_on_sync_reconciliation"
      add_index :billing_subscriptions,
        [
          :id,
          :organization_id,
          :provider,
          :environment,
          :provider_subscription_id,
          :origin_checkout_attempt_id
        ],
        unique: true,
        name: "index_billing_subscriptions_on_origin_locator_identity"

      add_foreign_key :billing_subscriptions,
        :plan_prices,
        column: :origin_plan_price_id,
        on_delete: :restrict,
        name: "fk_billing_subscriptions_origin_plan_price"
      add_foreign_key :billing_subscriptions,
        :billing_checkout_attempts,
        column: [
          :origin_checkout_attempt_id,
          :organization_id,
          :origin_plan_price_id,
          :provider,
          :environment
        ],
        primary_key: [ :id, :organization_id, :plan_price_id, :provider, :environment ],
        on_delete: :restrict,
        name: "fk_billing_subscriptions_origin_checkout_identity"

      add_check_constraint :billing_subscriptions,
        "sync_state IN ('synced', 'pending', 'mapping_error', 'invalid')",
        name: "billing_subscriptions_sync_state_allowed"
      add_check_constraint :billing_subscriptions,
        "last_seen_provider_updated_at >= provider_updated_at",
        name: "billing_subscriptions_seen_update_monotonic"
    end

    def expand_provider_locators
      add_column :billing_provider_locators, :provider_subscription_id, :string, limit: 128
      add_column :billing_provider_locators, :billing_subscription_id, :bigint

      add_index :billing_provider_locators,
        [ :provider, :environment, :provider_subscription_id ],
        unique: true,
        where: "provider_subscription_id IS NOT NULL",
        name: "index_billing_provider_locators_on_subscription_identity"
      add_index :billing_provider_locators,
        :billing_subscription_id,
        unique: true,
        where: "billing_subscription_id IS NOT NULL",
        name: "index_billing_provider_locators_on_billing_subscription"

      add_foreign_key :billing_provider_locators,
        :billing_subscriptions,
        column: [
          :billing_subscription_id,
          :organization_id,
          :provider,
          :environment,
          :provider_subscription_id,
          :billing_checkout_attempt_id
        ],
        primary_key: [
          :id,
          :organization_id,
          :provider,
          :environment,
          :provider_subscription_id,
          :origin_checkout_attempt_id
        ],
        on_delete: :restrict,
        name: "fk_billing_provider_locators_subscription_identity"

      remove_check_constraint :billing_provider_locators,
        name: "billing_provider_locators_lifecycle"
      add_check_constraint :billing_provider_locators,
        provider_locator_lifecycle_sql,
        name: "billing_provider_locators_lifecycle"
      add_check_constraint :billing_provider_locators,
        <<~SQL.squish,
          provider_subscription_id IS NULL OR (
            provider_subscription_id = btrim(provider_subscription_id)
            AND provider_subscription_id !~ '[[:space:]]'
            AND char_length(provider_subscription_id) BETWEEN 1 AND 128
          )
        SQL
        name: "billing_provider_locators_subscription_id_normalized"
    end

    def relax_completed_checkout_lifecycle
      remove_check_constraint :billing_checkout_attempts,
        name: "billing_checkout_attempts_lifecycle"
      add_check_constraint :billing_checkout_attempts,
        checkout_lifecycle_sql(require_completed_provider_id: false),
        name: "billing_checkout_attempts_lifecycle"
    end

    def restore_completed_checkout_lifecycle
      if select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*)
        FROM billing_checkout_attempts
        WHERE status = 'completed' AND provider_checkout_id IS NULL
      SQL
        raise ActiveRecord::IrreversibleMigration,
          "completed checkout attempts without provider checkout IDs require remediation"
      end

      remove_check_constraint :billing_checkout_attempts,
        name: "billing_checkout_attempts_lifecycle"
      add_check_constraint :billing_checkout_attempts,
        checkout_lifecycle_sql(require_completed_provider_id: true),
        name: "billing_checkout_attempts_lifecycle"
    end

    def contract_provider_locators
      remove_check_constraint :billing_provider_locators,
        name: "billing_provider_locators_subscription_id_normalized"
      remove_check_constraint :billing_provider_locators,
        name: "billing_provider_locators_lifecycle"
      add_check_constraint :billing_provider_locators,
        <<~SQL.squish,
          (
            status = 'unresolved'
            AND resolved_at IS NULL
          ) OR (
            status IN ('consumed', 'definitive_creation_failure')
            AND resolved_at IS NOT NULL
          )
        SQL
        name: "billing_provider_locators_lifecycle"

      remove_foreign_key :billing_provider_locators,
        name: "fk_billing_provider_locators_subscription_identity"
      remove_index :billing_provider_locators,
        name: "index_billing_provider_locators_on_billing_subscription"
      remove_index :billing_provider_locators,
        name: "index_billing_provider_locators_on_subscription_identity"
      remove_column :billing_provider_locators, :billing_subscription_id
      remove_column :billing_provider_locators, :provider_subscription_id
    end

    def contract_subscriptions
      remove_check_constraint :billing_subscriptions,
        name: "billing_subscriptions_seen_update_monotonic"
      remove_check_constraint :billing_subscriptions,
        name: "billing_subscriptions_sync_state_allowed"
      remove_foreign_key :billing_subscriptions,
        name: "fk_billing_subscriptions_origin_checkout_identity"
      remove_foreign_key :billing_subscriptions,
        name: "fk_billing_subscriptions_origin_plan_price"
      remove_index :billing_subscriptions,
        name: "index_billing_subscriptions_on_sync_reconciliation"
      if index_exists?(:billing_subscriptions, name: "index_billing_subscriptions_on_origin_locator_identity")
        remove_index :billing_subscriptions,
          name: "index_billing_subscriptions_on_origin_locator_identity"
      end
      remove_index :billing_subscriptions,
        name: "index_billing_subscriptions_on_origin_checkout_attempt"
      remove_index :billing_subscriptions,
        name: "index_billing_subscriptions_on_origin_plan_price"
      remove_column :billing_subscriptions, :origin_checkout_attempt_id
      remove_column :billing_subscriptions, :origin_plan_price_id
      remove_column :billing_subscriptions, :sync_state
      remove_column :billing_subscriptions, :last_seen_provider_updated_at
    end

    def remove_verified_webhook_ingress_marker
      if check_constraint_exists?(:billing_webhook_events, name: "billing_webhook_events_ingress_version_allowed")
        remove_check_constraint :billing_webhook_events,
          name: "billing_webhook_events_ingress_version_allowed"
      end
      if index_exists?(:billing_webhook_events, name: "index_billing_webhook_events_on_verified_recovery")
        remove_index :billing_webhook_events,
          name: "index_billing_webhook_events_on_verified_recovery"
      end
      remove_column :billing_webhook_events, :ingress_version if column_exists?(:billing_webhook_events, :ingress_version)
    end

    def provider_locator_lifecycle_sql
      <<~SQL.squish
        (
          status = 'unresolved'
          AND resolved_at IS NULL
          AND provider_subscription_id IS NULL
          AND billing_subscription_id IS NULL
        ) OR (
          status = 'consumed'
          AND resolved_at IS NOT NULL
          AND provider_subscription_id IS NOT NULL
        ) OR (
          status = 'definitive_creation_failure'
          AND resolved_at IS NOT NULL
          AND provider_subscription_id IS NULL
          AND billing_subscription_id IS NULL
        )
      SQL
    end

    def checkout_lifecycle_sql(require_completed_provider_id:)
      completed_provider_requirement = if require_completed_provider_id
        "AND provider_checkout_id IS NOT NULL"
      end

      <<~SQL.squish
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
          #{completed_provider_requirement}
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
    end
end
