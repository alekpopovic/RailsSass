class CreatePlatformAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :platform_audit_events do |t|
      t.references :actor_user,
        null: false,
        foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :action, null: false, limit: 32
      t.string :subject_type, null: false, limit: 64
      t.bigint :subject_id, null: false
      t.string :subject_key, null: false, limit: 255
      t.jsonb :change_set, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :platform_audit_events,
      [ :actor_user_id, :occurred_at ],
      name: "index_platform_audit_events_on_actor_and_occurred_at"
    add_index :platform_audit_events,
      [ :subject_type, :subject_id ],
      name: "index_platform_audit_events_on_subject"
    add_index :platform_audit_events,
      [ :subject_type, :subject_key ],
      name: "index_platform_audit_events_on_subject_key"
    add_index :platform_audit_events,
      [ :action, :occurred_at ],
      name: "index_platform_audit_events_on_action_and_occurred_at"

    add_check_constraint :platform_audit_events,
      "action IN ('catalog.created', 'catalog.updated', 'catalog.deactivated')",
      name: "platform_audit_events_action_allowed"
    add_check_constraint :platform_audit_events,
      <<~SQL.squish,
        subject_type IN (
          'Product', 'ProductFeature', 'Plan', 'PlanProduct',
          'PlanFeatureEntitlement', 'PlanPrice'
        )
      SQL
      name: "platform_audit_events_subject_type_allowed"
    add_check_constraint :platform_audit_events,
      "subject_id > 0",
      name: "platform_audit_events_subject_id_positive"
    add_check_constraint :platform_audit_events,
      <<~SQL.squish,
        subject_key = btrim(subject_key)
        AND char_length(subject_key) BETWEEN 1 AND 255
      SQL
      name: "platform_audit_events_subject_key_normalized"
    add_check_constraint :platform_audit_events,
      "jsonb_typeof(change_set) = 'object' AND pg_column_size(change_set) <= 16384",
      name: "platform_audit_events_change_set_object_bounded"

    execute <<~SQL
      CREATE FUNCTION public.prevent_platform_audit_event_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $function$
      BEGIN
        RAISE EXCEPTION 'platform audit events are append-only'
          USING ERRCODE = '55000',
            TABLE = 'platform_audit_events';
      END;
      $function$;

      CREATE TRIGGER platform_audit_events_are_append_only
      BEFORE UPDATE OR DELETE ON platform_audit_events
      FOR EACH ROW
      EXECUTE FUNCTION public.prevent_platform_audit_event_mutation();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS platform_audit_events_are_append_only
        ON platform_audit_events;
      DROP FUNCTION IF EXISTS public.prevent_platform_audit_event_mutation();
    SQL

    drop_table :platform_audit_events
  end
end
