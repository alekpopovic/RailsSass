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

    %w[organization_id action subject_type subject_id metadata created_at].each do |column_name|
      assert_not columns.fetch(column_name).null, "expected #{column_name} to be NOT NULL"
    end
    assert_not columns.key?("updated_at")
    assert_not columns.fetch("occurred_at").null
    assert columns.fetch("actor_user_id").null
    assert_equal "{}", columns.fetch("metadata").default

    indexes = AuditEvent.connection.indexes(:audit_events).index_by(&:name)
    assert indexes.key?("index_audit_events_on_organization_id_and_created_at")

    constraints = AuditEvent.connection.check_constraints(:audit_events).index_by(&:name)
    metadata_constraint = constraints.fetch("audit_events_metadata_object_bounded")
    assert_match(/pg_column_size\(metadata\).*16384/, metadata_constraint.expression)
    assert constraints.key?("audit_events_compatibility_timestamps_match")

    trigger_count = AuditEvent.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM pg_trigger
      WHERE tgrelid = 'audit_events'::regclass
        AND tgname = 'audit_events_are_append_only'
        AND NOT tgisinternal
    SQL
    assert_equal 1, trigger_count
  end

  test "audit timestamp compatibility trigger supports old and new writers" do
    owner = User.create!(
      name: "Audit timestamp owner",
      email_address: "audit-timestamp-#{SecureRandom.hex(5)}@example.test",
      password: "Correct-Horse-Battery-Staple-123!",
      password_confirmation: "Correct-Horse-Battery-Staple-123!",
      email_verified_at: Time.current
    )
    organization = Organization.create!(
      name: "Audit timestamp organization",
      slug: "audit-timestamp-#{SecureRandom.hex(5)}"
    )
    organization.organization_memberships.create!(
      user: owner,
      role: :owner,
      status: :active,
      joined_at: Time.current
    )
    occurred_at = Time.current.change(usec: 0)
    quoted_time = AuditEvent.connection.quote(occurred_at)
    event_id = AuditEvent.connection.select_value(<<~SQL)
      INSERT INTO audit_events (
        organization_id, action, subject_type, subject_id, metadata, occurred_at
      ) VALUES (
        #{organization.id}, 'system.compatibility_checked', 'Organization',
        #{organization.id}, '{}'::jsonb, #{quoted_time}
      )
      RETURNING id
    SQL

    event = organization.audit_events.find(event_id)
    assert_equal event.occurred_at, event.created_at

    new_event = AuditEvents::Record.call(
      organization: organization,
      actor_user: owner,
      action: "system.current_writer_checked",
      subject: organization
    ).reload
    assert_equal new_event.created_at, new_event.occurred_at

    newer_created_at = occurred_at + 1.minute
    event_id = AuditEvent.connection.select_value(<<~SQL)
      INSERT INTO audit_events (
        organization_id, action, subject_type, subject_id, metadata,
        occurred_at, created_at
      ) VALUES (
        #{organization.id}, 'system.old_writer_restarted', 'Organization',
        #{organization.id}, '{}'::jsonb, #{quoted_time},
        #{AuditEvent.connection.quote(newer_created_at)}
      )
      RETURNING id
    SQL
    restarted_writer_event = organization.audit_events.find(event_id)
    assert_equal occurred_at, restarted_writer_event.occurred_at
    assert_equal occurred_at, restarted_writer_event.created_at
  end
end
