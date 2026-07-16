class AddPastDueStartedAtToBillingSubscriptions < ActiveRecord::Migration[8.1]
  def up
    add_column :billing_subscriptions, :past_due_started_at, :datetime

    add_check_constraint :billing_subscriptions,
      <<~SQL.squish,
        (
          status = 'past_due'
          AND past_due_started_at IS NOT NULL
          AND past_due_started_at <= provider_updated_at
        ) OR (
          status <> 'past_due'
          AND past_due_started_at IS NULL
        )
      SQL
      name: "billing_subscriptions_past_due_cycle_consistent",
      validate: false
  end

  def down
    remove_check_constraint :billing_subscriptions,
      name: "billing_subscriptions_past_due_cycle_consistent"
    remove_column :billing_subscriptions, :past_due_started_at
  end
end
