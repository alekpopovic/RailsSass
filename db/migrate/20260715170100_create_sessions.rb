class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false, limit: 64
      t.inet :ip_address
      t.string :user_agent, limit: 512
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :sessions, :token_digest, unique: true
    add_index :sessions, :expires_at

    add_check_constraint :sessions,
      "token_digest ~ '^[0-9a-f]{64}$'",
      name: "sessions_token_digest_format"
    add_check_constraint :sessions,
      "user_agent IS NULL OR char_length(user_agent) <= 512",
      name: "sessions_user_agent_length"
    add_check_constraint :sessions,
      "expires_at > created_at",
      name: "sessions_expiry_after_creation"
  end
end
