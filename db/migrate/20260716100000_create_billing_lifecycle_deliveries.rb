class CreateBillingLifecycleDeliveries < ActiveRecord::Migration[8.1]
  KINDS = %w[
    subscription_activated
    payment_problem
    cancellation_scheduled
    subscription_expired
    plan_change_completed
  ].freeze
  STATUSES = %w[pending processing delivered failed discarded].freeze

  def change
    add_index :audit_events,
      [ :id, :organization_id ],
      unique: true,
      name: "index_audit_events_on_id_and_organization_id"
    add_index :billing_subscriptions,
      [ :id, :organization_id ],
      unique: true,
      name: "index_billing_subscriptions_on_id_and_organization_id"
    add_index :billing_webhook_events,
      [ :id, :organization_id ],
      unique: true,
      name: "index_billing_webhook_events_on_id_and_organization_id"

    create_table :billing_lifecycle_deliveries do |t|
      t.references :organization,
        null: false,
        foreign_key: { on_delete: :restrict }
      t.bigint :audit_event_id, null: false
      t.bigint :billing_subscription_id, null: false
      t.bigint :source_webhook_event_id, null: false
      t.bigint :recipient_user_id, null: false
      t.string :kind, null: false, limit: 40
      t.string :status, null: false, default: "pending", limit: 16
      t.integer :attempts_count, null: false, default: 0
      t.datetime :available_at, null: false
      t.datetime :enqueued_at
      t.datetime :claimed_at
      t.datetime :delivered_at
      t.string :failure_code, limit: 64

      t.timestamps null: false
    end

    add_index :billing_lifecycle_deliveries,
      :audit_event_id,
      name: "index_billing_lifecycle_deliveries_on_audit_event"
    add_index :billing_lifecycle_deliveries,
      :billing_subscription_id,
      name: "index_billing_lifecycle_deliveries_on_subscription"
    add_index :billing_lifecycle_deliveries,
      :recipient_user_id,
      name: "index_billing_lifecycle_deliveries_on_recipient"
    add_index :billing_lifecycle_deliveries,
      [ :source_webhook_event_id, :kind, :recipient_user_id ],
      unique: true,
      name: "index_billing_lifecycle_deliveries_on_dedupe_identity"
    add_index :billing_lifecycle_deliveries,
      [ :organization_id, :status, :available_at ],
      name: "index_billing_lifecycle_deliveries_on_tenant_recovery"
    add_index :billing_lifecycle_deliveries,
      [ :status, :claimed_at ],
      where: "status = 'processing'",
      name: "index_billing_lifecycle_deliveries_on_processing_lease"

    add_foreign_key :billing_lifecycle_deliveries,
      :audit_events,
      column: [ :audit_event_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict,
      name: "fk_billing_lifecycle_deliveries_audit_tenant"
    add_foreign_key :billing_lifecycle_deliveries,
      :billing_subscriptions,
      column: [ :billing_subscription_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict,
      name: "fk_billing_lifecycle_deliveries_subscription_tenant"
    add_foreign_key :billing_lifecycle_deliveries,
      :billing_webhook_events,
      column: [ :source_webhook_event_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict,
      name: "fk_billing_lifecycle_deliveries_webhook_tenant"
    add_foreign_key :billing_lifecycle_deliveries,
      :users,
      column: :recipient_user_id,
      on_delete: :restrict,
      name: "fk_billing_lifecycle_deliveries_recipient"
    add_foreign_key :billing_lifecycle_deliveries,
      :organization_memberships,
      column: [ :organization_id, :recipient_user_id ],
      primary_key: [ :organization_id, :user_id ],
      on_delete: :restrict,
      name: "fk_billing_lifecycle_deliveries_recipient_membership"

    add_check_constraint :billing_lifecycle_deliveries,
      "kind IN (#{KINDS.map { |kind| quote(kind) }.join(', ')})",
      name: "billing_lifecycle_deliveries_kind_allowed"
    add_check_constraint :billing_lifecycle_deliveries,
      "status IN (#{STATUSES.map { |status| quote(status) }.join(', ')})",
      name: "billing_lifecycle_deliveries_status_allowed"
    add_check_constraint :billing_lifecycle_deliveries,
      "attempts_count >= 0",
      name: "billing_lifecycle_deliveries_attempts_non_negative"
    add_check_constraint :billing_lifecycle_deliveries,
      <<~SQL.squish,
        (
          status = 'pending' AND claimed_at IS NULL AND delivered_at IS NULL
          AND failure_code IS NULL
        ) OR (
          status = 'processing' AND claimed_at IS NOT NULL AND delivered_at IS NULL
          AND failure_code IS NULL
        ) OR (
          status = 'delivered' AND claimed_at IS NOT NULL AND delivered_at IS NOT NULL
          AND failure_code IS NULL
        ) OR (
          status IN ('failed', 'discarded') AND claimed_at IS NOT NULL
          AND delivered_at IS NULL AND failure_code IS NOT NULL
        )
      SQL
      name: "billing_lifecycle_deliveries_lifecycle"
    add_check_constraint :billing_lifecycle_deliveries,
      "enqueued_at IS NULL OR enqueued_at >= created_at",
      name: "billing_lifecycle_deliveries_enqueued_after_creation"
    add_check_constraint :billing_lifecycle_deliveries,
      "claimed_at IS NULL OR claimed_at >= available_at",
      name: "billing_lifecycle_deliveries_claimed_after_available"
    add_check_constraint :billing_lifecycle_deliveries,
      "delivered_at IS NULL OR delivered_at >= claimed_at",
      name: "billing_lifecycle_deliveries_delivered_after_claim"
    add_check_constraint :billing_lifecycle_deliveries,
      <<~SQL.squish,
        failure_code IS NULL OR (
          failure_code = btrim(failure_code)
          AND failure_code ~ '^[a-z][a-z0-9_]*$'
          AND char_length(failure_code) BETWEEN 1 AND 64
        )
      SQL
      name: "billing_lifecycle_deliveries_failure_code_normalized"
  end

  private
    def quote(value)
      connection.quote(value)
    end
end
