class CreateProductRbac < ActiveRecord::Migration[8.1]
  def change
    add_index :organization_memberships,
      [ :id, :organization_id, :status ],
      unique: true,
      name: "index_org_memberships_on_id_org_and_status"

    create_product_permissions
    create_product_roles
    create_product_role_permissions
    create_product_memberships
    create_product_membership_roles
    install_product_role_integrity_triggers
  end

  private
    def create_product_permissions
      create_table :product_permissions do |t|
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :key, null: false, limit: 100
        t.string :name, null: false, limit: 100
        t.text :description, null: false, default: ""

        t.timestamps null: false
      end

      add_index :product_permissions, [ :product_id, :key ], unique: true
      add_index :product_permissions, [ :id, :product_id ], unique: true,
        name: "index_product_permissions_on_id_and_product_id"

      add_check_constraint :product_permissions,
        "key ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*" \
          "([.][a-z][a-z0-9]*(_[a-z0-9]+)*)+$' " \
          "AND char_length(key) BETWEEN 3 AND 100",
        name: "product_permissions_key_format"
      add_normalized_name_and_description_constraints(:product_permissions)
    end

    def create_product_roles
      create_table :product_roles do |t|
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :organization,
          null: true,
          foreign_key: { on_delete: :restrict }
        t.string :key, null: false, limit: 63
        t.string :name, null: false, limit: 100
        t.boolean :system, null: false, default: true
        t.boolean :active, null: false, default: true

        t.timestamps null: false
      end

      add_index :product_roles,
        [ :product_id, :key ],
        unique: true,
        where: "organization_id IS NULL",
        name: "index_product_roles_on_system_product_and_key"
      add_index :product_roles,
        [ :organization_id, :product_id, :key ],
        unique: true,
        where: "organization_id IS NOT NULL",
        name: "index_product_roles_on_organization_product_and_key"
      add_index :product_roles, [ :id, :product_id ], unique: true,
        name: "index_product_roles_on_id_and_product_id"
      add_index :product_roles, [ :product_id, :active ]
      add_index :product_roles, [ :organization_id, :product_id, :active ],
        name: "index_product_roles_on_org_product_and_active"

      add_check_constraint :product_roles,
        "key ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$' " \
          "AND char_length(key) BETWEEN 1 AND 63",
        name: "product_roles_key_format"
      add_check_constraint :product_roles,
        <<~SQL.squish,
          (
            system = TRUE
            AND organization_id IS NULL
          ) OR (
            system = FALSE
            AND organization_id IS NOT NULL
          )
        SQL
        name: "product_roles_system_scope_consistent"
      add_check_constraint :product_roles,
        "name = btrim(name) AND char_length(name) BETWEEN 1 AND 100",
        name: "product_roles_name_normalized"
    end

    def create_product_role_permissions
      create_table :product_role_permissions do |t|
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.bigint :product_role_id, null: false
        t.bigint :product_permission_id, null: false

        t.timestamps null: false
      end

      add_index :product_role_permissions,
        [ :product_role_id, :product_permission_id ],
        unique: true,
        name: "index_product_role_permissions_on_role_and_permission"
      add_index :product_role_permissions, [ :product_role_id, :product_id ],
        name: "index_product_role_permissions_on_role_and_product"
      add_index :product_role_permissions, [ :product_permission_id, :product_id ],
        name: "index_product_role_permissions_on_permission_and_product"

      add_foreign_key :product_role_permissions,
        :product_roles,
        column: [ :product_role_id, :product_id ],
        primary_key: [ :id, :product_id ],
        on_delete: :restrict,
        name: "fk_product_role_permissions_role_product"
      add_foreign_key :product_role_permissions,
        :product_permissions,
        column: [ :product_permission_id, :product_id ],
        primary_key: [ :id, :product_id ],
        on_delete: :restrict,
        name: "fk_product_role_permissions_permission_product"
    end

    def create_product_memberships
      create_table :product_memberships do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.bigint :organization_membership_id, null: false
        t.string :organization_membership_status,
          null: false,
          default: "active",
          limit: 16
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.string :status, null: false, default: "active", limit: 16

        t.timestamps null: false
      end

      add_index :product_memberships,
        [ :organization_membership_id, :product_id ],
        unique: true,
        name: "index_product_memberships_on_membership_and_product"
      add_index :product_memberships,
        [ :id, :organization_id, :product_id ],
        unique: true,
        name: "index_product_memberships_on_id_org_and_product"
      add_index :product_memberships,
        [ :organization_membership_id, :organization_id, :organization_membership_status ],
        name: "index_product_memberships_on_active_org_membership"
      add_index :product_memberships, [ :organization_id, :product_id, :status ],
        name: "index_product_memberships_on_org_product_and_status"

      add_foreign_key :product_memberships,
        :organization_memberships,
        column: [
          :organization_membership_id,
          :organization_id,
          :organization_membership_status
        ],
        primary_key: [ :id, :organization_id, :status ],
        on_delete: :restrict,
        name: "fk_product_memberships_active_organization_membership"

      add_check_constraint :product_memberships,
        "organization_membership_status = 'active'",
        name: "product_memberships_parent_membership_active"
      add_check_constraint :product_memberships,
        "status IN ('active', 'suspended')",
        name: "product_memberships_status_allowed"
    end

    def create_product_membership_roles
      create_table :product_membership_roles do |t|
        t.references :organization,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.references :product,
          null: false,
          foreign_key: { on_delete: :restrict }
        t.bigint :product_membership_id, null: false
        t.bigint :product_role_id, null: false

        t.timestamps null: false
      end

      add_index :product_membership_roles,
        [ :product_membership_id, :product_role_id ],
        unique: true,
        name: "index_product_membership_roles_on_membership_and_role"
      add_index :product_membership_roles,
        [ :product_membership_id, :organization_id, :product_id ],
        name: "index_product_membership_roles_on_membership_org_product"
      add_index :product_membership_roles, [ :product_role_id, :product_id ],
        name: "index_product_membership_roles_on_role_and_product"
      add_index :product_membership_roles, [ :organization_id, :product_id ],
        name: "index_product_membership_roles_on_org_and_product"

      add_foreign_key :product_membership_roles,
        :product_memberships,
        column: [ :product_membership_id, :organization_id, :product_id ],
        primary_key: [ :id, :organization_id, :product_id ],
        on_delete: :cascade,
        name: "fk_product_membership_roles_membership_scope"
      add_foreign_key :product_membership_roles,
        :product_roles,
        column: [ :product_role_id, :product_id ],
        primary_key: [ :id, :product_id ],
        on_delete: :restrict,
        name: "fk_product_membership_roles_role_product"
    end

    def install_product_role_integrity_triggers
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION public.protect_product_role_identity()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, public
            AS $function$
            BEGIN
              IF NEW.product_id IS DISTINCT FROM OLD.product_id
                OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
                OR NEW.key IS DISTINCT FROM OLD.key
                OR NEW.system IS DISTINCT FROM OLD.system THEN
                RAISE EXCEPTION 'product role identity is immutable'
                  USING ERRCODE = '23514',
                    CONSTRAINT = 'product_roles_identity_immutable',
                    TABLE = 'product_roles';
              END IF;

              RETURN NEW;
            END;
            $function$;

            CREATE TRIGGER product_roles_identity_is_immutable
            BEFORE UPDATE OF product_id, organization_id, key, system
            ON product_roles
            FOR EACH ROW
            EXECUTE FUNCTION public.protect_product_role_identity();

            CREATE FUNCTION public.enforce_product_membership_role_scope()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, public
            AS $function$
            DECLARE
              role_organization_id bigint;
              role_active boolean;
            BEGIN
              SELECT organization_id, active
              INTO role_organization_id, role_active
              FROM public.product_roles
              WHERE id = NEW.product_role_id
                AND product_id = NEW.product_id
              FOR SHARE;

              IF NOT FOUND THEN
                RETURN NEW;
              END IF;

              IF role_active = FALSE THEN
                RAISE EXCEPTION 'inactive product role cannot be assigned'
                  USING ERRCODE = '23514',
                    CONSTRAINT = 'product_membership_roles_role_active',
                    TABLE = 'product_membership_roles';
              END IF;

              IF role_organization_id IS NOT NULL
                AND role_organization_id IS DISTINCT FROM NEW.organization_id THEN
                RAISE EXCEPTION 'organization product role belongs to another organization'
                  USING ERRCODE = '23514',
                    CONSTRAINT = 'product_membership_roles_role_organization_matches',
                    TABLE = 'product_membership_roles';
              END IF;

              RETURN NEW;
            END;
            $function$;

            CREATE TRIGGER product_membership_roles_scope_is_valid
            BEFORE INSERT OR UPDATE OF organization_id, product_id, product_role_id
            ON product_membership_roles
            FOR EACH ROW
            EXECUTE FUNCTION public.enforce_product_membership_role_scope();
          SQL
        end

        direction.down do
          execute <<~SQL
            DROP TRIGGER IF EXISTS product_membership_roles_scope_is_valid
              ON product_membership_roles;
            DROP FUNCTION IF EXISTS public.enforce_product_membership_role_scope();

            DROP TRIGGER IF EXISTS product_roles_identity_is_immutable
              ON product_roles;
            DROP FUNCTION IF EXISTS public.protect_product_role_identity();
          SQL
        end
      end
    end

    def add_normalized_name_and_description_constraints(table_name)
      add_check_constraint table_name,
        "name = btrim(name) AND char_length(name) BETWEEN 1 AND 100",
        name: "#{table_name}_name_normalized"
      add_check_constraint table_name,
        "description = btrim(description) AND char_length(description) <= 2000",
        name: "#{table_name}_description_normalized"
    end
end
