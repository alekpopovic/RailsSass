# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_15_170100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.inet "ip_address"
    t.string "token_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.string "user_agent", limit: 512
    t.bigint "user_id", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
    t.check_constraint "expires_at > created_at", name: "sessions_expiry_after_creation"
    t.check_constraint "token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "sessions_token_digest_format"
    t.check_constraint "user_agent IS NULL OR char_length(user_agent::text) <= 512", name: "sessions_user_agent_length"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "disabled_at"
    t.string "email_address", limit: 254, null: false
    t.datetime "email_verified_at"
    t.string "name", limit: 100, null: false
    t.string "password_digest", limit: 255, null: false
    t.string "system_role", limit: 32, default: "user", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_users_on_lower_email_address", unique: true
    t.index ["system_role"], name: "index_users_on_system_role"
    t.check_constraint "char_length(password_digest::text) >= 1 AND char_length(password_digest::text) <= 255", name: "users_password_digest_present"
    t.check_constraint "email_address::text = lower(btrim(email_address::text)) AND char_length(email_address::text) >= 3 AND char_length(email_address::text) <= 254", name: "users_email_address_normalized"
    t.check_constraint "name::text = btrim(name::text) AND char_length(name::text) >= 1 AND char_length(name::text) <= 100", name: "users_name_normalized"
    t.check_constraint "system_role::text = ANY (ARRAY['user'::character varying, 'platform_admin'::character varying]::text[])", name: "users_system_role_allowed"
  end

  add_foreign_key "sessions", "users", on_delete: :cascade
end
