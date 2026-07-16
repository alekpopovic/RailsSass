require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationAuditEventsRequestTest < ActionDispatch::IntegrationTest
  include OrganizationTestHelper

  setup do
    suffix = SecureRandom.hex(4)
    @owner = create_test_user(
      name: "Audit Owner",
      email_address: "audit-viewer-owner-#{suffix}@example.test"
    )
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Audit Viewer Organization",
      slug: "audit-viewer-#{suffix}"
    )
    create_locator_for(@owner_membership)
    sign_in_as(@owner)
  end

  test "owners and admins can open the read-only viewer from tenant navigation" do
    event = create_event(
      organization: @organization,
      actor: @owner,
      action: "organization.settings.updated"
    )

    get organization_audit_events_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "h1", "Audit log"
    assert_select "a[href=?]",
      organization_audit_events_path(organization_slug: @organization.slug),
      text: "Audit log"
    assert_select "li[data-audit-event-id='#{event.id}']"
    assert_select "section[aria-labelledby='audit-log-title'] form", count: 0

    delete session_path
    admin = create_test_user(
      name: "Audit Admin",
      email_address: "audit-viewer-admin-#{SecureRandom.hex(4)}@example.test"
    )
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    create_locator_for(admin_membership)
    sign_in_as(admin)

    get organization_audit_events_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "li[data-audit-event-id='#{event.id}']"
  end

  test "billing members ordinary members and platform admins have no organization audit bypass" do
    delete session_path

    [ :billing, :member, :platform_admin ].each do |actor_kind|
      user = create_test_user(
        email_address: "audit-viewer-denied-#{actor_kind}-#{SecureRandom.hex(4)}@example.test"
      )
      user.update!(system_role: :platform_admin) if actor_kind == :platform_admin
      membership = create_test_membership(
        organization: @organization,
        user: user,
        role: actor_kind == :platform_admin ? :member : actor_kind
      )
      create_locator_for(membership)
      sign_in_as(user)

      get organization_audit_events_path(organization_slug: @organization.slug)

      assert_response :forbidden
      assert_select "title", "Forbidden (403)"
      delete session_path
    end
  end

  test "viewer is tenant isolated newest first bounded and renders only allowlisted details" do
    foreign_owner = create_test_user(
      name: "Foreign Audit Actor",
      email_address: "foreign-audit-viewer-#{SecureRandom.hex(4)}@example.test"
    )
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Audit Viewer Organization",
      slug: "foreign-audit-viewer-#{SecureRandom.hex(4)}"
    )
    create_event(
      organization: foreign_organization,
      actor: foreign_owner,
      action: "organization.settings.updated",
      created_at: 1.day.from_now
    )

    base_time = 2.hours.ago
    events = 51.times.map do |index|
      create_event(
        organization: @organization,
        actor: index == 50 ? nil : @owner,
        action: index == 50 ? "provider.private_projection" : "organization.settings.updated",
        subject_type: index == 50 ? "PrivateProviderPayload" : "Organization",
        metadata: index == 50 ? {
          "organization_role" => "admin",
          "email_address" => "private@example.test",
          "reset_token" => "plaintext-reset-token",
          "raw_payload" => { "customer" => "private" }
        } : {},
        created_at: base_time + index.seconds
      )
    end

    get organization_audit_events_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "li[data-audit-event-id]", count: 50
    assert_select "li[data-audit-event-id='#{events.last.id}']", text: /System \/ provider/
    assert_select "li[data-audit-event-id='#{events.first.id}']", count: 0
    assert_select "nav[aria-label='Audit log pages'] a", text: "Next"
    assert_match "Organization activity", response.body
    assert_select "dt", text: "Role"
    assert_select "dd", text: "Admin"
    assert_no_match "Foreign Audit Actor", response.body
    assert_no_match "provider.private_projection", response.body
    assert_no_match "PrivateProviderPayload", response.body
    assert_no_match "private@example.test", response.body
    assert_no_match "plaintext-reset-token", response.body
    assert_no_match(/raw_payload|customer.*private/m, response.body)
    assert_operator response.body.index(%(data-audit-event-id="#{events.last.id}")),
      :<,
      response.body.index(%(data-audit-event-id="#{events[25].id}"))

    get organization_audit_events_path(organization_slug: @organization.slug, page: 2)

    assert_response :success
    assert_select "li[data-audit-event-id]", count: 1
    assert_select "li[data-audit-event-id='#{events.first.id}']"
    assert_select "nav[aria-label='Audit log pages'] a", text: "Previous"
    assert_select "nav[aria-label='Audit log pages'] a", text: "Next", count: 0

    get organization_audit_events_path(organization_slug: @organization.slug, page: 0)
    assert_response :not_found

    get organization_audit_events_path(organization_slug: @organization.slug, page: 10_001)
    assert_response :not_found
  end

  test "audit log has no mutation route" do
    path = organization_audit_events_path(organization_slug: @organization.slug)

    %i[post patch put delete].each do |method|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(path, method: method)
      end
    end
  end

  private
    def create_locator_for(membership)
      OrganizationAccessLocator.find_or_create_by!(
        organization_membership: membership,
        organization: membership.organization,
        user: membership.user
      )
    end

    def create_event(
      organization:,
      actor:,
      action:,
      subject_type: "Organization",
      metadata: {},
      created_at: Time.current
    )
      organization.audit_events.create!(
        actor_user: actor,
        action: action,
        subject_type: subject_type,
        subject_id: organization.id,
        metadata: metadata,
        created_at: created_at
      )
    end
end
