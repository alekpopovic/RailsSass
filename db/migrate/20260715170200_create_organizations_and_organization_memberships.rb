class CreateOrganizationsAndOrganizationMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :name, null: false, limit: 100
      t.string :slug, null: false, limit: 63
      t.string :status, null: false, default: "active", limit: 16

      t.timestamps
    end

    add_index :organizations, :public_id, unique: true
    add_index :organizations, :slug, unique: true
    add_index :organizations, :status

    add_check_constraint :organizations,
      "name = btrim(name) AND char_length(name) BETWEEN 1 AND 100",
      name: "organizations_name_normalized"
    add_check_constraint :organizations,
      "slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) BETWEEN 1 AND 63",
      name: "organizations_slug_format"
    add_check_constraint :organizations,
      "status IN ('active', 'suspended')",
      name: "organizations_status_allowed"

    create_table :organization_memberships do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.string :role, null: false, limit: 16
      t.string :status, null: false, default: "active", limit: 16
      t.datetime :joined_at, null: false

      t.timestamps
    end

    add_index :organization_memberships, [ :organization_id, :user_id ], unique: true
    add_index :organization_memberships, [ :organization_id, :status, :role ]
    add_index :organization_memberships, [ :id, :organization_id ], unique: true,
      name: "index_org_memberships_on_id_and_organization_id"
    add_index :organization_memberships, [ :id, :user_id, :organization_id ], unique: true,
      name: "index_org_memberships_on_id_user_id_organization_id"

    add_check_constraint :organization_memberships,
      "role IN ('owner', 'admin', 'billing', 'member')",
      name: "organization_memberships_role_allowed"
    add_check_constraint :organization_memberships,
      "status IN ('active', 'suspended')",
      name: "organization_memberships_status_allowed"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION public.enforce_organization_active_owner()
          RETURNS trigger
          LANGUAGE plpgsql
          SET search_path = pg_catalog, public
          AS $function$
          DECLARE
            affected_organization_id bigint;
            affected_organization_ids bigint[];
          BEGIN
            IF TG_TABLE_NAME = 'organizations' THEN
              affected_organization_ids := ARRAY[NEW.id];
            ELSIF TG_OP = 'INSERT' THEN
              affected_organization_ids := ARRAY[NEW.organization_id];
            ELSIF TG_OP = 'DELETE' THEN
              affected_organization_ids := ARRAY[OLD.organization_id];
            ELSE
              SELECT array_agg(candidate_id ORDER BY candidate_id)
              INTO affected_organization_ids
              FROM (
                SELECT DISTINCT unnest(
                  ARRAY[OLD.organization_id, NEW.organization_id]
                ) AS candidate_id
              ) AS candidates;
            END IF;

            FOREACH affected_organization_id IN ARRAY affected_organization_ids
            LOOP
              PERFORM 1
              FROM public.organizations
              WHERE id = affected_organization_id
              FOR UPDATE;

              IF FOUND AND NOT EXISTS (
                SELECT 1
                FROM public.organization_memberships
                WHERE organization_id = affected_organization_id
                  AND role = 'owner'
                  AND status = 'active'
              ) THEN
                RAISE EXCEPTION
                  'organization % must have at least one active owner',
                  affected_organization_id
                  USING ERRCODE = '23514',
                    CONSTRAINT = 'organization_must_have_active_owner',
                    TABLE = 'organizations';
              END IF;
            END LOOP;

            RETURN NULL;
          END;
          $function$;

          CREATE CONSTRAINT TRIGGER organization_must_have_active_owner
          AFTER INSERT ON organizations
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW
          EXECUTE FUNCTION public.enforce_organization_active_owner();

          CREATE CONSTRAINT TRIGGER organization_must_have_active_owner
          AFTER INSERT OR UPDATE OR DELETE ON organization_memberships
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW
          EXECUTE FUNCTION public.enforce_organization_active_owner();
        SQL
      end

      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS organization_must_have_active_owner
            ON organization_memberships;
          DROP TRIGGER IF EXISTS organization_must_have_active_owner
            ON organizations;
          DROP FUNCTION IF EXISTS public.enforce_organization_active_owner();
        SQL
      end
    end
  end
end
