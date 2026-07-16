class AlignAuditEventsWithImmutableContract < ActiveRecord::Migration[8.1]
  CREATED_AT_INDEX = "index_audit_events_on_organization_id_and_created_at"
  TIMESTAMP_CHECK = "audit_events_compatibility_timestamps_match"
  TIMESTAMP_TRIGGER = "audit_events_synchronize_compatibility_timestamps"

  def up
    add_column :audit_events, :created_at, :datetime
    execute "ALTER TABLE audit_events DISABLE TRIGGER audit_events_are_append_only"
    execute <<~SQL
      UPDATE audit_events
      SET created_at = occurred_at
      WHERE created_at IS NULL
    SQL
    execute "ALTER TABLE audit_events ENABLE TRIGGER audit_events_are_append_only"
    change_column_null :audit_events, :created_at, false
    add_index :audit_events,
      [ :organization_id, :created_at ],
      name: CREATED_AT_INDEX
    add_check_constraint :audit_events,
      "created_at = occurred_at",
      name: TIMESTAMP_CHECK
    create_compatibility_timestamp_trigger

    remove_check_constraint :audit_events,
      name: "audit_events_metadata_object"
    add_check_constraint :audit_events,
      "jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 16384",
      name: "audit_events_metadata_object_bounded"
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS #{TIMESTAMP_TRIGGER} ON audit_events;
      DROP FUNCTION IF EXISTS public.synchronize_audit_event_timestamps();
    SQL
    remove_check_constraint :audit_events, name: TIMESTAMP_CHECK
    remove_index :audit_events, name: CREATED_AT_INDEX
    remove_column :audit_events, :created_at

    remove_check_constraint :audit_events,
      name: "audit_events_metadata_object_bounded"
    add_check_constraint :audit_events,
      "jsonb_typeof(metadata) = 'object'",
      name: "audit_events_metadata_object"
  end

  private
    def create_compatibility_timestamp_trigger
      execute <<~SQL
        CREATE FUNCTION public.synchronize_audit_event_timestamps()
        RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, public
        AS $function$
        BEGIN
          NEW.occurred_at := COALESCE(NEW.occurred_at, NEW.created_at);
          NEW.created_at := NEW.occurred_at;

          RETURN NEW;
        END;
        $function$;

        CREATE TRIGGER #{TIMESTAMP_TRIGGER}
        BEFORE INSERT ON audit_events
        FOR EACH ROW
        EXECUTE FUNCTION public.synchronize_audit_event_timestamps();
      SQL
    end
end
