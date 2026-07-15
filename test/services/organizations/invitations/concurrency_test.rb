require "test_helper"
require "timeout"
require_relative "../../../support/audit_event_test_helper"
require_relative "../../../support/organization_test_helper"

class Organizations::Invitations::ConcurrencyTest < ActiveSupport::TestCase
  include AuditEventTestHelper
  include OrganizationTestHelper

  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @owner = create_test_user(email_address: "concurrent-invite-owner-#{suffix}@example.test")
    @recipient = create_test_user(email_address: "concurrent-invite-recipient-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Concurrent Invitation Organization",
      slug: "concurrent-invitation-#{suffix}"
    )
    @owner_session = establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    delivery = Organizations::Invitations::Create.new(
      actor: @owner,
      email_address: @recipient.email_address,
      organization_role: :member
    ).call
    @invitation = delivery.invitation
    @raw_token = delivery.raw_token
    @recipient_session, = Session.issue_for!(
      @recipient,
      ip_address: nil,
      user_agent: "Invitation concurrency test"
    )
    Current.reset
  end

  teardown do
    Current.reset
    clear_test_audit_events!
    Session.where(id: [ @owner_session&.id, @recipient_session&.id ].compact).delete_all
    if @organization
      OrganizationInvitation.where(organization_id: @organization.id).delete_all
      OrganizationAccessLocator.where(organization_id: @organization.id).delete_all
      Organization.transaction do
        OrganizationMembership.where(organization_id: @organization.id).delete_all
        Organization.where(id: @organization.id).delete_all
      end
    end
    User.where(id: [ @owner&.id, @recipient&.id ].compact).delete_all
  ensure
    Current.reset
  end

  test "concurrent acceptance has one effect and creates one membership and locator" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.session = Session.includes(:user).find(@recipient_session.id)
          Current.organization = Organization.find(@organization.id)
          Current.membership = nil
          ready << true
          start.pop

          membership = Organizations::Invitations::Accept.new(
            user: Current.user,
            raw_token: @raw_token
          ).call
          results << membership
        rescue => error
          results << error
        ensure
          Current.reset
        end
      end
    end

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(5) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(OrganizationMembership) }
    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(ActiveRecord::RecordNotFound) }
    membership = @organization.organization_memberships.find_by!(user_id: @recipient.id)
    assert_predicate membership, :active?
    assert_equal 1, @organization.organization_memberships.where(user_id: @recipient.id).count
    assert_equal 1, @organization.organization_access_locators
      .where(organization_membership_id: membership.id)
      .count
    assert_predicate @invitation.reload, :accepted?
  ensure
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end
end
