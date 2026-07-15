class CreateOrganizationAccessLocators < ActiveRecord::Migration[8.1]
  def up
    create_table :organization_access_locators do |t|
      t.references :organization_membership, null: false, index: { unique: true }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }

      t.timestamps null: false
    end

    add_index :organization_access_locators, [ :user_id, :organization_id ], unique: true,
      name: "index_org_access_locators_on_user_and_organization"

    add_foreign_key :organization_access_locators,
      :organization_memberships,
      column: [ :organization_membership_id, :user_id, :organization_id ],
      primary_key: [ :id, :user_id, :organization_id ],
      on_delete: :restrict,
      name: "fk_org_access_locators_membership_identity"

    backfill_active_memberships
    verify_active_membership_backfill!
  end

  def down
    drop_table :organization_access_locators
  end

  private
    def backfill_active_memberships
      execute <<~SQL
      INSERT INTO organization_access_locators (
        organization_membership_id,
        user_id,
        organization_id,
        created_at,
        updated_at
      )
      SELECT
        id,
        user_id,
        organization_id,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM organization_memberships
      WHERE status = 'active'
      ON CONFLICT (organization_membership_id) DO NOTHING
      SQL
    end

    def verify_active_membership_backfill!
      incomplete_locator_count = select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM organization_memberships AS memberships
        LEFT JOIN organization_access_locators AS locators
          ON locators.organization_membership_id = memberships.id
         AND locators.user_id = memberships.user_id
         AND locators.organization_id = memberships.organization_id
        WHERE memberships.status = 'active'
          AND locators.id IS NULL
      SQL

      return if incomplete_locator_count.zero?

      raise ActiveRecord::MigrationError,
        "organization access locator backfill is incomplete for #{incomplete_locator_count} active memberships"
    end
end
