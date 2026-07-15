require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationInvitationMailerTest < ActionMailer::TestCase
  include OrganizationTestHelper

  test "invitation email contains an explicit tenant URL with a query token" do
    inviter = create_test_user(name: "Invitation Owner", email_address: "invitation-owner@example.test")
    organization, = create_test_organization_with_owner(
      owner: inviter,
      name: "Mailer Organization",
      slug: "mailer-organization"
    )
    raw_token = SecureRandom.urlsafe_base64(32)
    invitation = organization.organization_invitations.create!(
      inviter: inviter,
      email_address: "  INVITEE@EXAMPLE.TEST ",
      organization_role: :admin,
      status: :pending,
      token_digest: OrganizationInvitation.digest_token(raw_token),
      expires_at: 7.days.from_now
    )

    process_payloads = []
    delivery_payloads = []
    process_subscription = ActiveSupport::Notifications.subscribe("process.action_mailer") do |event|
      process_payloads << event.payload
    end
    delivery_subscription = ActiveSupport::Notifications.subscribe("deliver.action_mailer") do |event|
      delivery_payloads << event.payload
    end

    email = OrganizationInvitationMailer.deliver_invitation!(
      invitation: invitation,
      raw_token: raw_token
    )
    invitation_uri = URI.parse(URI.extract(email.text_part.body.to_s, %w[http https]).first)

    assert_equal [ "invitee@example.test" ], email.to
    assert_equal "You're invited to Mailer Organization", email.subject
    assert_equal "/o/mailer-organization/invitations/accept", invitation_uri.path
    assert_equal raw_token, Rack::Utils.parse_nested_query(invitation_uri.query)["token"]
    assert_not_includes invitation_uri.path, raw_token
    assert_not_includes email.body.to_s, invitation.token_digest
    assert_equal [ [] ], process_payloads.map { |payload| payload.fetch(:args) }
    assert_equal [ "[FILTERED]" ], delivery_payloads.map { |payload| payload.fetch(:mail) }
    assert_no_match raw_token, process_payloads.inspect
    assert_no_match raw_token, delivery_payloads.inspect
    assert_nil OrganizationInvitationMailer::DeliveryContext.raw_token
  ensure
    ActiveSupport::Notifications.unsubscribe(process_subscription) if process_subscription
    ActiveSupport::Notifications.unsubscribe(delivery_subscription) if delivery_subscription
  end
end
