class CreateAnalyticsReports < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_reports do |t|
      t.references :organization,
        null: false,
        foreign_key: { on_delete: :restrict }
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :name, null: false, limit: 100
      t.text :description, null: false, default: ""

      t.timestamps null: false
    end

    add_index :analytics_reports, :public_id, unique: true
    add_index :analytics_reports,
      [ :organization_id, :created_at, :id ],
      name: "index_analytics_reports_on_org_created_at_and_id"

    add_check_constraint :analytics_reports,
      "name = btrim(name) AND char_length(name) BETWEEN 1 AND 100",
      name: "analytics_reports_name_normalized"
    add_check_constraint :analytics_reports,
      "description = btrim(description) AND char_length(description) <= 2000",
      name: "analytics_reports_description_normalized"
  end
end
