class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false, limit: 100
      t.string :email_address, null: false, limit: 254
      t.string :password_digest, null: false, limit: 255
      t.datetime :email_verified_at
      t.string :system_role, null: false, default: "user", limit: 32
      t.datetime :disabled_at

      t.timestamps
    end

    add_index :users, "lower(email_address)", unique: true,
      name: "index_users_on_lower_email_address"
    add_index :users, :system_role

    add_check_constraint :users,
      "name = btrim(name) AND char_length(name) BETWEEN 1 AND 100",
      name: "users_name_normalized"
    add_check_constraint :users,
      "email_address = lower(btrim(email_address)) AND char_length(email_address) BETWEEN 3 AND 254",
      name: "users_email_address_normalized"
    add_check_constraint :users,
      "char_length(password_digest) BETWEEN 1 AND 255",
      name: "users_password_digest_present"
    add_check_constraint :users,
      "system_role IN ('user', 'platform_admin')",
      name: "users_system_role_allowed"
  end
end
