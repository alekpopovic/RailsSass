class BoundPlanFeatureEntitlementSettings < ActiveRecord::Migration[8.1]
  ORIGINAL_CONSTRAINT = "plan_feature_entitlements_settings_object"
  BOUNDED_CONSTRAINT = "plan_feature_entitlements_settings_object_bounded"

  def up
    add_check_constraint :plan_feature_entitlements,
      "jsonb_typeof(settings) = 'object' AND pg_column_size(settings) <= 65536",
      name: BOUNDED_CONSTRAINT
    remove_check_constraint :plan_feature_entitlements, name: ORIGINAL_CONSTRAINT
  end

  def down
    add_check_constraint :plan_feature_entitlements,
      "jsonb_typeof(settings) = 'object'",
      name: ORIGINAL_CONSTRAINT
    remove_check_constraint :plan_feature_entitlements, name: BOUNDED_CONSTRAINT
  end
end
