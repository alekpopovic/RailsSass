class AddWebhookIngressFields < ActiveRecord::Migration[8.1]
  def up
    add_column :billing_webhook_events, :external_resource_type, :string, limit: 64
    add_column :billing_webhook_events, :external_resource_id, :string, limit: 128
    add_column :billing_webhook_events, :body_sha256, :string, limit: 64
    add_column :billing_webhook_events, :payload, :jsonb, null: false, default: {}
    add_column :billing_webhook_events, :processing_started_at, :datetime
    add_column :billing_webhook_events, :failed_at, :datetime
    add_column :billing_webhook_events, :attempts_count, :integer, null: false, default: 0
    add_column :billing_webhook_events, :error_class, :string, limit: 255
    add_column :billing_webhook_events, :error_message, :string, limit: 500
    add_column :billing_webhook_events, :enqueued_at, :datetime

    execute <<~SQL.squish
      UPDATE billing_webhook_events
      SET body_sha256 = fingerprint,
          external_resource_type = snapshot->>'resource_type',
          external_resource_id = provider_resource_id,
          payload = snapshot,
          attempts_count = attempt_count,
          failed_at = CASE WHEN status = 'failed' THEN processed_at ELSE NULL END
    SQL

    change_column_null :billing_webhook_events, :body_sha256, false

    add_index :billing_webhook_events,
      [ :provider, :environment, :body_sha256 ],
      unique: true,
      name: "index_billing_webhook_events_on_body_identity"
    add_index :billing_webhook_events,
      [ :status, :enqueued_at, :received_at ],
      name: "index_billing_webhook_events_on_enqueue_recovery"

    add_check_constraint :billing_webhook_events,
      "body_sha256 ~ '^[0-9a-f]{64}$'",
      name: "billing_webhook_events_body_sha256_format"
    add_check_constraint :billing_webhook_events,
      <<~SQL.squish,
        external_resource_type IS NULL OR (
          external_resource_type = btrim(external_resource_type)
          AND external_resource_type ~ '^[a-z][a-z0-9_-]*$'
          AND char_length(external_resource_type) BETWEEN 1 AND 64
        )
      SQL
      name: "billing_webhook_events_resource_type_normalized"
    add_check_constraint :billing_webhook_events,
      <<~SQL.squish,
        external_resource_id IS NULL OR (
          external_resource_id = btrim(external_resource_id)
          AND external_resource_id !~ '[[:space:]]'
          AND char_length(external_resource_id) BETWEEN 1 AND 128
        )
      SQL
      name: "billing_webhook_events_external_resource_id_normalized"
    add_check_constraint :billing_webhook_events,
      "external_resource_id IS NOT DISTINCT FROM provider_resource_id",
      name: "billing_webhook_events_resource_id_compatibility"
    add_check_constraint :billing_webhook_events,
      "payload = snapshot",
      name: "billing_webhook_events_payload_compatibility"
    add_check_constraint :billing_webhook_events,
      "attempts_count = attempt_count AND attempts_count >= 0",
      name: "billing_webhook_events_attempts_compatibility"
    add_check_constraint :billing_webhook_events,
      "jsonb_typeof(payload) = 'object' AND pg_column_size(payload) <= 65536",
      name: "billing_webhook_events_payload_object_bounded"
    add_check_constraint :billing_webhook_events,
      "processing_started_at IS NULL OR processing_started_at >= verified_at",
      name: "billing_webhook_events_processing_after_verified"
    add_check_constraint :billing_webhook_events,
      <<~SQL.squish,
        processed_at IS NULL OR processing_started_at IS NULL
        OR processed_at >= processing_started_at
      SQL
      name: "billing_webhook_events_processed_after_processing"
    add_check_constraint :billing_webhook_events,
      <<~SQL.squish,
        failed_at IS NULL OR (
          failed_at >= verified_at
          AND (processing_started_at IS NULL OR failed_at >= processing_started_at)
        )
      SQL
      name: "billing_webhook_events_failed_after_processing"
    add_check_constraint :billing_webhook_events,
      <<~SQL.squish,
        error_class IS NULL OR (
          error_class = btrim(error_class)
          AND error_class !~ '[[:cntrl:]]'
          AND char_length(error_class) BETWEEN 1 AND 255
        )
      SQL
      name: "billing_webhook_events_error_class_normalized"
    add_check_constraint :billing_webhook_events,
      <<~SQL.squish,
        error_message IS NULL OR (
          error_message = btrim(error_message)
          AND error_message !~ '[[:cntrl:]]'
          AND char_length(error_message) BETWEEN 1 AND 500
        )
      SQL
      name: "billing_webhook_events_error_message_normalized"
    add_check_constraint :billing_webhook_events,
      "enqueued_at IS NULL OR enqueued_at >= verified_at",
      name: "billing_webhook_events_enqueued_after_verified"
  end

  def down
    remove_column :billing_webhook_events, :enqueued_at
    remove_column :billing_webhook_events, :error_message
    remove_column :billing_webhook_events, :error_class
    remove_column :billing_webhook_events, :attempts_count
    remove_column :billing_webhook_events, :failed_at
    remove_column :billing_webhook_events, :processing_started_at
    remove_column :billing_webhook_events, :payload
    remove_column :billing_webhook_events, :body_sha256
    remove_column :billing_webhook_events, :external_resource_id
    remove_column :billing_webhook_events, :external_resource_type
  end
end
