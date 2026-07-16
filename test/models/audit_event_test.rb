require "test_helper"
require_relative "../support/organization_test_helper"

class AuditEventTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "audit-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(owner: @owner)
  end

  test "belongs to a tenant and an optional actor" do
    event = create_event
    system_event = create_event(actor_user: nil, action: "system.reconciled")

    assert_equal @organization, event.organization
    assert_equal @owner, event.actor_user
    assert_equal @owner, event.actor
    assert_equal @owner.id, event.actor_id
    assert_nil system_event.actor_user
    assert_includes @organization.audit_events, event
    assert_includes @owner.audit_events_as_actor, event
    assert_includes @owner_membership.audit_events_as_actor, event
  end

  test "database composite foreign key rejects an actor outside the tenant" do
    other_owner = create_test_user(email_address: "other-audit-actor@example.test")
    create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Audit Organization",
      slug: "other-audit-organization"
    )

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      AuditEvent.insert_all!([ raw_attributes(actor_user_id: other_owner.id) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database rejects malformed actions" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.insert_all!([ raw_attributes(action: "Invitation Accepted") ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database requires metadata to be a JSON object" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.insert_all!([ raw_attributes(metadata: [ "not", "an", "object" ]) ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database bounds metadata size" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.insert_all!([ raw_attributes(metadata: { "value" => "x" * 20_000 }) ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "persisted audit events are readonly through the model" do
    event = create_event

    assert_predicate event, :readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      event.update!(action: "invitation.revoked")
    end
  end

  test "database trigger rejects direct updates" do
    event = create_event

    error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.where(id: event.id).update_all(action: "invitation.revoked")
    end

    assert_kind_of PG::ObjectNotInPrerequisiteState, error.cause
  end

  test "database trigger rejects direct deletes" do
    event = create_event

    error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.where(id: event.id).delete_all
    end

    assert_kind_of PG::ObjectNotInPrerequisiteState, error.cause
  end

  private
    def create_event(**overrides)
      @organization.audit_events.create!({
        actor_user: @owner,
        action: "invitation.created",
        subject_type: "OrganizationInvitation",
        subject_id: 123,
        metadata: { "organization_role" => "member" },
        created_at: Time.current
      }.merge(overrides))
    end

    def raw_attributes(**overrides)
      {
        organization_id: @organization.id,
        actor_user_id: @owner.id,
        action: "invitation.created",
        subject_type: "OrganizationInvitation",
        subject_id: 123,
        request_id: nil,
        job_id: nil,
        metadata: {},
        created_at: Time.current
      }.merge(overrides)
    end
end
