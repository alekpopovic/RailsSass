require "test_helper"

class CreatePlatformAuditEventsTest < ActiveSupport::TestCase
  test "platform audit columns, indexes, constraints, and actor foreign key are installed" do
    columns = Platform::AuditEvent.columns.index_by(&:name)

    %w[
      actor_user_id action subject_type subject_id subject_key change_set occurred_at created_at
    ].each do |column_name|
      assert_not columns.fetch(column_name).null, "expected #{column_name} to be NOT NULL"
    end
    assert_equal "{}", columns.fetch("change_set").default

    indexes = Platform::AuditEvent.connection
      .indexes(:platform_audit_events)
      .index_by(&:name)
    %w[
      index_platform_audit_events_on_actor_and_occurred_at
      index_platform_audit_events_on_subject
      index_platform_audit_events_on_subject_key
      index_platform_audit_events_on_action_and_occurred_at
    ].each { |name| assert indexes.key?(name), "expected index #{name}" }

    constraint_names = Platform::AuditEvent.connection
      .check_constraints(:platform_audit_events)
      .map(&:name)
    %w[
      platform_audit_events_action_allowed
      platform_audit_events_subject_type_allowed
      platform_audit_events_subject_id_positive
      platform_audit_events_subject_key_normalized
      platform_audit_events_change_set_object_bounded
    ].each { |name| assert_includes constraint_names, name }

    actor_foreign_key = Platform::AuditEvent.connection
      .foreign_keys(:platform_audit_events)
      .find { |foreign_key| foreign_key.column == "actor_user_id" }
    assert_equal "users", actor_foreign_key.to_table
    assert_equal :restrict, actor_foreign_key.on_delete
  end

  test "append-only database trigger is installed" do
    trigger_count = Platform::AuditEvent.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM pg_trigger
      WHERE tgrelid = 'platform_audit_events'::regclass
        AND tgname = 'platform_audit_events_are_append_only'
        AND NOT tgisinternal
    SQL

    assert_equal 1, trigger_count
  end
end
