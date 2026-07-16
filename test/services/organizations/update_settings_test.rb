require "test_helper"
require_relative "../../support/organization_test_helper"

class Organizations::UpdateSettingsTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "settings-service-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Original Organization",
      slug: "settings-service-organization"
    )
    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
  end

  teardown do
    Current.reset
  end

  test "updates the current organization name and records one tenant audit event" do
    updated = nil

    assert_difference -> { @organization.audit_events.count }, 1 do
      updated = Organizations::UpdateSettings.new(
        actor: @owner,
        name: "  Renamed Organization  "
      ).call
    end

    assert_equal @organization, updated
    assert_equal "Renamed Organization", @organization.reload.name
    event = @organization.audit_events.order(:id).last!
    assert_equal "organization.settings.updated", event.action
    assert_equal "Organization", event.subject_type
    assert_equal @organization.id, event.subject_id
    assert_equal @owner.id, event.actor_user_id
    assert_empty event.metadata
  end

  test "a normalized no-op does not create audit noise" do
    assert_no_difference -> { @organization.audit_events.count } do
      Organizations::UpdateSettings.new(
        actor: @owner,
        name: " Original Organization "
      ).call
    end
  end

  test "an admin may update but billing and member roles are rejected" do
    admin = create_test_user(email_address: "settings-service-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    establish_tenant_context(
      user: admin,
      organization: @organization,
      membership: admin_membership
    )

    Organizations::UpdateSettings.new(actor: admin, name: "Admin Rename").call
    assert_equal "Admin Rename", @organization.reload.name

    %i[billing member].each do |role|
      actor = create_test_user(email_address: "settings-service-#{role}@example.test")
      membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: role
      )
      establish_tenant_context(
        user: actor,
        organization: @organization,
        membership: membership
      )

      assert_raises(Pundit::NotAuthorizedError) do
        Organizations::UpdateSettings.new(actor: actor, name: "Denied Rename").call
      end
    end

    assert_equal "Admin Rename", @organization.reload.name
  end

  test "invalid input and revoked live context change neither organization nor audit ledger" do
    assert_no_difference -> { @organization.audit_events.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        Organizations::UpdateSettings.new(actor: @owner, name: "").call
      end
    end
    assert_equal "Original Organization", @organization.reload.name

    Session.where(id: Current.session.id).delete_all
    assert_no_difference -> { @organization.audit_events.count } do
      assert_raises(Pundit::NotAuthorizedError) do
        Organizations::UpdateSettings.new(actor: @owner, name: "Stale Rename").call
      end
    end
    assert_equal "Original Organization", @organization.reload.name
  end
end
