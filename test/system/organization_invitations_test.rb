require "application_system_test_case"
require "active_job/test_helper"
require "action_mailer/test_helper"
require "nokogiri"
require "uri"
require_relative "../support/organization_test_helper"

class OrganizationInvitationsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include OrganizationTestHelper

  INVITEE_PASSWORD = "system-invitation-password-123"

  setup do
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
    @owner = create_test_user(email_address: "system-invitation-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "System Invitation Organization",
      slug: "system-invitation-organization"
    )
    OrganizationAccessLocator.create!(
      organization_membership: @owner_membership,
      organization: @organization,
      user: @owner
    )
  end

  test "owner invites a new user who registers verifies and accepts" do
    visit new_session_path
    fill_in "Email address", with: @owner.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
    assert_current_path root_path
    assert_text @owner.name
    visit organization_members_path(organization_slug: @organization.slug)

    page.current_window.resize_to(390, 844)
    click_link "Invite member"
    fill_in "Email address", with: "SYSTEM.NEW.INVITEE@EXAMPLE.TEST"
    select "Admin", from: "Organization role"
    click_button "Send invitation"

    assert_current_path organization_members_path(organization_slug: @organization.slug)
    assert_selector "[role='status']", text: "Invitation sent."
    invitation_link = mail_link(subject: "You're invited to System Invitation Organization")

    click_button "Sign out"
    visit invitation_link

    assert_current_path new_session_path
    assert_selector "[role='alert']", text: /reopen the invitation link/i
    within "#main-content" do
      click_link "Register"
    end
    fill_in "Name", with: "System New Invitee"
    fill_in "Email address", with: "system.new.invitee@example.test"
    fill_in "Password", with: INVITEE_PASSWORD
    fill_in "Confirm password", with: INVITEE_PASSWORD
    click_button "Create account"

    assert_current_path new_session_path
    assert_selector "[role='status']", text: RegistrationsController::GENERIC_NOTICE
    invitee = User.find_by!(email_address: "system.new.invitee@example.test")
    UserMailer.email_verification(invitee).deliver_now
    verification_link = mail_link(subject: "Verify your email address")
    visit verification_link
    click_button "Verify email address"
    fill_in "Email address", with: "system.new.invitee@example.test"
    fill_in "Password", with: INVITEE_PASSWORD
    click_button "Sign in"

    assert_current_path new_organization_path
    visit invitation_link
    assert_selector "h1", text: "Join System Invitation Organization"
    find_button("Accept invitation").send_keys(:enter)

    assert_current_path organization_dashboard_path(organization_slug: @organization.slug)
    assert_selector "[role='status']", text: "Invitation accepted."
    membership = @organization.organization_memberships.find_by!(user: invitee)
    assert_predicate membership, :admin?
    assert OrganizationAccessLocator.exists?(organization_membership_id: membership.id)
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "owner administers roles membership status and invitation lifecycle" do
    member = create_test_user(
      name: "System Managed Member",
      email_address: "system-managed-member@example.test"
    )
    membership = create_test_membership(
      organization: @organization,
      user: member,
      role: :member
    )
    OrganizationAccessLocator.create!(
      organization_membership: membership,
      organization: @organization,
      user: member
    )
    sign_in_owner
    visit organization_members_path(organization_slug: @organization.slug)

    within_member_row("System Managed Member") do
      select "Admin", from: "Role for System Managed Member"
      click_button "Update role"
    end
    assert_selector "[role='status']", text: "Member role updated."
    assert_predicate membership.reload, :admin?

    within_member_row("System Managed Member") do
      click_button "Suspend"
    end
    assert_selector "[role='status']", text: "Member suspended."
    assert_predicate membership.reload, :suspended?

    within_member_row("System Managed Member") do
      click_button "Reactivate"
    end
    assert_selector "[role='status']", text: "Member reactivated."
    assert_predicate membership.reload, :active?

    click_link "Invite member"
    fill_in "Email address", with: "lifecycle-invitee@example.test"
    select "Member", from: "Organization role"
    click_button "Send invitation"
    assert_current_path organization_members_path(organization_slug: @organization.slug)
    assert_selector "[role='status']", text: "Invitation sent."
    invitation = @organization.organization_invitations.find_by!(
      email_address: "lifecycle-invitee@example.test"
    )

    within_invitation_row("lifecycle-invitee@example.test") do
      click_button "Resend"
    end
    assert_selector "[role='status']", text: "Invitation resent."
    assert_predicate invitation.reload, :pending?

    within_invitation_row("lifecycle-invitee@example.test") do
      click_button "Revoke"
    end
    assert_selector "[role='status']", text: "Invitation revoked."
    assert_predicate invitation.reload, :revoked?
    within_invitation_row("lifecycle-invitee@example.test") do
      assert_text "Revoked"
      assert_no_button "Resend"
      assert_no_button "Revoke"
    end
  end

  private
    def sign_in_owner
      visit new_session_path
      fill_in "Email address", with: @owner.email_address
      fill_in "Password", with: TEST_PASSWORD
      click_button "Sign in"
      assert_current_path root_path
    end

    def within_member_row(name, &block)
      within(find("section[aria-labelledby='current-members-title'] li", text: name), &block)
    end

    def within_invitation_row(email_address, &block)
      within(find("section[aria-labelledby='invitations-title'] li", text: email_address), &block)
    end

    def mail_link(subject:)
      message = ActionMailer::Base.deliveries.reverse.find { |mail| mail.subject == subject }
      assert_not_nil message, "Expected an email with subject #{subject.inspect}"

      document = Nokogiri::HTML(message.html_part.body.decoded)
      href = document.at_css("a")&.[]("href")
      assert_not_nil href, "Expected the email to contain a link"

      uri = URI.parse(href)
      uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    end
end
