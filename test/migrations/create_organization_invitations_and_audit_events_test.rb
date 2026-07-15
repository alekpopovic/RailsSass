require "test_helper"

class CreateOrganizationInvitationsAndAuditEventsTest < ActiveSupport::TestCase
  test "invitation columns and lifecycle constraints are database enforced" do
    columns = OrganizationInvitation.columns.index_by(&:name)
    required_columns = %w[
      organization_id inviter_id email_address organization_role status
      token_digest expires_at created_at updated_at
    ]

    required_columns.each do |column_name|
      assert_not columns.fetch(column_name).null, "expected #{column_name} to be NOT NULL"
    end
    assert columns.fetch("accepted_at").null
    assert columns.fetch("revoked_at").null

    constraint_names = OrganizationInvitation.connection
      .check_constraints(:organization_invitations)
      .map(&:name)

    %w[
      organization_invitations_email_normalized
      organization_invitations_role_allowed
      organization_invitations_status_allowed
      organization_invitations_token_digest_format
      organization_invitations_expiry_after_creation
      organization_invitations_status_timestamps
      organization_invitations_accepted_at_valid
      organization_invitations_revoked_at_valid
    ].each { |name| assert_includes constraint_names, name }
  end

  test "invitation indexes enforce token and pending email uniqueness" do
    indexes = OrganizationInvitation.connection.indexes(:organization_invitations).index_by(&:name)

    assert_predicate indexes.fetch("index_organization_invitations_on_token_digest"), :unique
    pending_email = indexes.fetch("index_org_invitations_on_pending_email")
    assert_predicate pending_email, :unique
    assert_match(/status.*=.*pending/, pending_email.where)
  end

  test "inviter and audit actor have tenant-consistent composite foreign keys" do
    invitation_foreign_keys = OrganizationInvitation.connection
      .foreign_keys(:organization_invitations)
    audit_foreign_keys = AuditEvent.connection.foreign_keys(:audit_events)

    assert invitation_foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "organization_memberships" &&
        foreign_key.column == %w[organization_id inviter_id] &&
        foreign_key.primary_key == %w[organization_id user_id] &&
        foreign_key.on_delete == :restrict
    }
    assert audit_foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "organization_memberships" &&
        foreign_key.column == %w[organization_id actor_user_id] &&
        foreign_key.primary_key == %w[organization_id user_id] &&
        foreign_key.on_delete == :restrict
    }
  end

  test "audit event shape and append-only trigger are installed" do
    columns = AuditEvent.columns.index_by(&:name)

    %w[organization_id action subject_type subject_id metadata occurred_at].each do |column_name|
      assert_not columns.fetch(column_name).null, "expected #{column_name} to be NOT NULL"
    end
    assert columns.fetch("actor_user_id").null
    assert_equal "{}", columns.fetch("metadata").default

    trigger_count = AuditEvent.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM pg_trigger
      WHERE tgrelid = 'audit_events'::regclass
        AND tgname = 'audit_events_are_append_only'
        AND NOT tgisinternal
    SQL
    assert_equal 1, trigger_count
  end
end
