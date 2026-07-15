class CreateOrganizationInvitationsAndAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_organization_invitations
    create_audit_events
    create_audit_event_append_only_trigger
  end

  def down
    drop_table :audit_events
    execute "DROP FUNCTION IF EXISTS public.prevent_audit_event_mutation()"
    drop_table :organization_invitations
  end

  private
    def create_organization_invitations
      create_table :organization_invitations do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :inviter,
          null: false,
          foreign_key: { to_table: :users, on_delete: :restrict }
        t.string :email_address, null: false, limit: 254
        t.string :organization_role, null: false, limit: 16
        t.string :status, null: false, default: "pending", limit: 16
        t.string :token_digest, null: false, limit: 64
        t.datetime :expires_at, null: false
        t.datetime :accepted_at
        t.datetime :revoked_at

        t.timestamps null: false
      end

      add_index :organization_invitations, :token_digest, unique: true
      add_index :organization_invitations,
        "organization_id, lower(email_address)",
        unique: true,
        where: "status = 'pending'",
        name: "index_org_invitations_on_pending_email"
      add_index :organization_invitations,
        [ :organization_id, :inviter_id ],
        name: "index_org_invitations_on_org_and_inviter"
      add_index :organization_invitations,
        [ :organization_id, :status, :created_at ],
        name: "index_org_invitations_on_org_status_created"
      add_index :organization_invitations,
        [ :organization_id, :status, :expires_at ],
        name: "index_org_invitations_on_org_status_expiry"

      add_foreign_key :organization_invitations,
        :organization_memberships,
        column: [ :organization_id, :inviter_id ],
        primary_key: [ :organization_id, :user_id ],
        on_delete: :restrict,
        name: "fk_org_invitations_inviter_membership"

      add_check_constraint :organization_invitations,
        "email_address = lower(btrim(email_address)) AND " \
          "char_length(email_address) BETWEEN 3 AND 254",
        name: "organization_invitations_email_normalized"
      add_check_constraint :organization_invitations,
        "organization_role IN ('owner', 'admin', 'billing', 'member')",
        name: "organization_invitations_role_allowed"
      add_check_constraint :organization_invitations,
        "status IN ('pending', 'accepted', 'revoked', 'expired')",
        name: "organization_invitations_status_allowed"
      add_check_constraint :organization_invitations,
        "token_digest ~ '^[0-9a-f]{64}$'",
        name: "organization_invitations_token_digest_format"
      add_check_constraint :organization_invitations,
        "expires_at > created_at",
        name: "organization_invitations_expiry_after_creation"
      add_check_constraint :organization_invitations,
        <<~SQL.squish,
          (
            status IN ('pending', 'expired')
            AND accepted_at IS NULL
            AND revoked_at IS NULL
          ) OR (
            status = 'accepted'
            AND accepted_at IS NOT NULL
            AND revoked_at IS NULL
          ) OR (
            status = 'revoked'
            AND accepted_at IS NULL
            AND revoked_at IS NOT NULL
          )
        SQL
        name: "organization_invitations_status_timestamps"
      add_check_constraint :organization_invitations,
        "accepted_at IS NULL OR " \
          "(accepted_at >= created_at AND accepted_at < expires_at)",
        name: "organization_invitations_accepted_at_valid"
      add_check_constraint :organization_invitations,
        "revoked_at IS NULL OR revoked_at >= created_at",
        name: "organization_invitations_revoked_at_valid"
    end

    def create_audit_events
      create_table :audit_events do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :actor_user,
          null: true,
          foreign_key: { to_table: :users, on_delete: :restrict }
        t.string :action, null: false, limit: 100
        t.string :subject_type, null: false, limit: 100
        t.bigint :subject_id, null: false
        t.string :request_id, limit: 255
        t.string :job_id, limit: 255
        t.jsonb :metadata, null: false, default: {}
        t.datetime :occurred_at, null: false
      end

      add_index :audit_events, [ :organization_id, :occurred_at ]
      add_index :audit_events, :action
      add_index :audit_events,
        [ :organization_id, :actor_user_id ],
        name: "index_audit_events_on_org_and_actor"

      add_foreign_key :audit_events,
        :organization_memberships,
        column: [ :organization_id, :actor_user_id ],
        primary_key: [ :organization_id, :user_id ],
        on_delete: :restrict,
        name: "fk_audit_events_actor_membership"

      add_check_constraint :audit_events,
        "action ~ '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$'",
        name: "audit_events_action_format"
      add_check_constraint :audit_events,
        "subject_type = btrim(subject_type) AND " \
          "char_length(subject_type) BETWEEN 1 AND 100",
        name: "audit_events_subject_type_present"
      add_check_constraint :audit_events,
        "subject_id > 0",
        name: "audit_events_subject_id_positive"
      add_check_constraint :audit_events,
        "request_id IS NULL OR " \
          "(request_id = btrim(request_id) AND char_length(request_id) BETWEEN 1 AND 255)",
        name: "audit_events_request_id_valid"
      add_check_constraint :audit_events,
        "job_id IS NULL OR " \
          "(job_id = btrim(job_id) AND char_length(job_id) BETWEEN 1 AND 255)",
        name: "audit_events_job_id_valid"
      add_check_constraint :audit_events,
        "jsonb_typeof(metadata) = 'object'",
        name: "audit_events_metadata_object"
    end

    def create_audit_event_append_only_trigger
      execute <<~SQL
        CREATE FUNCTION public.prevent_audit_event_mutation()
        RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, public
        AS $function$
        BEGIN
          RAISE EXCEPTION 'audit events are append-only'
            USING ERRCODE = '55000',
              TABLE = 'audit_events';
        END;
        $function$;

        CREATE TRIGGER audit_events_are_append_only
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW
        EXECUTE FUNCTION public.prevent_audit_event_mutation();
      SQL
    end
end
