require "test_helper"
require_relative "../support/organization_test_helper"

class AuditEventPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "audit-policy-owner-#{SecureRandom.hex(4)}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Audit Policy Organization",
      slug: "audit-policy-#{SecureRandom.hex(4)}"
    )
  end

  test "only active organization owners and admins can view the audit log" do
    expectations = { owner: true, admin: true, billing: false, member: false }

    expectations.each do |role, allowed|
      membership = role == :owner ? @owner_membership : membership_for(role)

      with_current_context(membership) do
        policy = AuditEventPolicy.new(context_for(membership), AuditEvent)

        assert_equal allowed, policy.index?, "expected #{role} audit access to be #{allowed}"
      end
    end

    platform_administrator = create_test_user(
      email_address: "audit-policy-platform-#{SecureRandom.hex(4)}@example.test"
    )
    platform_administrator.update!(system_role: :platform_admin)
    platform_membership = create_test_membership(
      organization: @organization,
      user: platform_administrator,
      role: :member
    )

    with_current_context(platform_membership) do
      assert_not AuditEventPolicy.new(context_for(platform_membership), AuditEvent).index?
    end
  end

  test "suspended memberships and organizations fail closed" do
    suspended_admin = membership_for(:admin, status: :suspended)

    with_current_context(suspended_admin) do
      assert_not AuditEventPolicy.new(context_for(suspended_admin), AuditEvent).index?
    end

    with_current_context(@owner_membership) do
      @organization.update!(status: :suspended)

      assert_not AuditEventPolicy.new(context_for(@owner_membership), AuditEvent).index?
    end
  end

  test "scope is rooted in Current organization and excludes another tenant" do
    own_event = create_event(organization: @organization, actor: @owner)
    foreign_owner = create_test_user(
      email_address: "audit-policy-foreign-#{SecureRandom.hex(4)}@example.test"
    )
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Audit Policy Organization",
      slug: "foreign-audit-policy-#{SecureRandom.hex(4)}"
    )
    foreign_event = create_event(organization: foreign_organization, actor: foreign_owner)
    candidate_scope = AuditEvent.where(id: [ own_event.id, foreign_event.id ])

    with_current_context(@owner_membership) do
      resolved = AuditEventPolicy::Scope.new(
        context_for(@owner_membership),
        candidate_scope
      ).resolve

      assert_equal [ own_event ], resolved.to_a
    end

    billing_membership = membership_for(:billing)
    with_current_context(billing_membership) do
      resolved = AuditEventPolicy::Scope.new(
        context_for(billing_membership),
        candidate_scope
      ).resolve

      assert_empty resolved
    end
  end

  test "policy and scope deny a revoked database session" do
    with_current_context(@owner_membership) do
      context = context_for(@owner_membership)
      Session.where(id: Current.session.id).delete_all

      assert_not AuditEventPolicy.new(context, AuditEvent).index?
      assert_empty AuditEventPolicy::Scope.new(context, AuditEvent.all).resolve
    end
  end

  private
    def membership_for(role, status: :active)
      user = create_test_user(
        email_address: "audit-policy-#{role}-#{status}-#{SecureRandom.hex(4)}@example.test"
      )
      create_test_membership(
        organization: @organization,
        user: user,
        role: role,
        status: status
      )
    end

    def with_current_context(membership, &block)
      session_record, = Session.issue_for!(
        membership.user,
        ip_address: nil,
        user_agent: "Audit policy test"
      )
      Current.set(
        session: session_record,
        organization: membership.organization,
        membership: membership,
        &block
      )
    end

    def context_for(membership)
      AuthorizationContext.new(
        user: membership.user,
        organization: membership.organization,
        membership: membership
      )
    end

    def create_event(organization:, actor:)
      organization.audit_events.create!(
        actor_user: actor,
        action: "organization.settings.updated",
        subject_type: "Organization",
        subject_id: organization.id,
        metadata: {},
        created_at: Time.current
      )
    end
end
