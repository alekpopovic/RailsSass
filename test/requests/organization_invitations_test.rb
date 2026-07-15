require "test_helper"
require "action_mailer/test_helper"
require "active_job/test_helper"
require "active_support/testing/time_helpers"
require_relative "../support/organization_test_helper"

class OrganizationInvitationsRequestTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers
  include OrganizationTestHelper

  INVITEE_PASSWORD = "invitation-password-123"

  setup do
    @owner = create_test_user(email_address: "invitation-request-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Invitation Request Organization",
      slug: "invitation-request-organization"
    )
    create_locator_for(@owner_membership)
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
  end

  teardown do
    Current.reset
    clear_enqueued_jobs
  end

  test "invitation routes keep the slug explicit and the token out of the path" do
    acceptance_path = organization_invitation_acceptance_path(
      organization_slug: @organization.slug,
      token: "raw invitation token"
    )

    assert_equal "/o/invitation-request-organization/invitations/new",
      new_organization_invitation_path(organization_slug: @organization.slug)
    assert_equal "/o/invitation-request-organization/invitations",
      organization_invitations_path(organization_slug: @organization.slug)
    assert_equal "/o/invitation-request-organization/invitations/accept?token=raw+invitation+token",
      acceptance_path
    assert_not_includes URI.parse(acceptance_path).path, "raw invitation token"
  end

  test "owner creates a normalized digest-only invitation and sends one email" do
    sign_in_as(@owner)

    assert_difference -> { OrganizationInvitation.count }, 1 do
      assert_emails 1 do
        post organization_invitations_path(organization_slug: @organization.slug), params: {
          organization_invitation: {
            email_address: "  NEW.INVITEE@EXAMPLE.TEST ",
            organization_role: "owner"
          }
        }
      end
    end

    invitation = @organization.organization_invitations.order(:created_at).last!
    raw_token = token_from_last_invitation_email

    assert_response :see_other
    assert_redirected_to organization_members_path(organization_slug: @organization.slug)
    assert_equal "new.invitee@example.test", invitation.email_address
    assert_predicate invitation, :owner?
    assert_equal @owner, invitation.inviter
    assert_equal OrganizationInvitation.digest_token(raw_token), invitation.token_digest
    assert_not_equal raw_token, invitation.token_digest
  end

  test "duplicate active invitation is deterministic and sends no replacement email" do
    sign_in_as(@owner)
    invitation_params = {
      organization_invitation: {
        email_address: "duplicate-invite@example.test",
        organization_role: "member"
      }
    }

    assert_emails 1 do
      post organization_invitations_path(organization_slug: @organization.slug), params: invitation_params
    end
    invitation = @organization.organization_invitations.sole
    original_digest = invitation.token_digest

    assert_no_difference -> { OrganizationInvitation.count } do
      assert_no_emails do
        post organization_invitations_path(organization_slug: @organization.slug), params: invitation_params
      end
    end

    assert_response :see_other
    assert_equal "An active invitation is already pending.", flash[:notice]
    assert_equal original_digest, invitation.reload.token_digest
  end

  test "an active organization member cannot be invited" do
    member = create_test_user(email_address: "already-active@example.test")
    create_test_membership(organization: @organization, user: member, role: :member)
    sign_in_as(@owner)

    assert_no_difference -> { OrganizationInvitation.count } do
      assert_no_emails do
        post organization_invitations_path(organization_slug: @organization.slug), params: {
          organization_invitation: {
            email_address: "  ALREADY-ACTIVE@EXAMPLE.TEST ",
            organization_role: "member"
          }
        }
      end
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']"
  end

  test "admin can invite member or admin but cannot invite owner or billing" do
    admin = create_test_user(email_address: "invitation-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    create_locator_for(admin_membership)
    sign_in_as(admin)

    get new_organization_invitation_path(organization_slug: @organization.slug)
    assert_response :success
    assert_select "select[name='organization_invitation[organization_role]']" do
      assert_select "option[value='admin']", "Admin"
      assert_select "option[value='member']", "Member"
      assert_select "option[value='owner']", count: 0
      assert_select "option[value='billing']", count: 0
    end

    %w[member admin].each do |role|
      assert_difference -> { OrganizationInvitation.count }, 1 do
        post organization_invitations_path(organization_slug: @organization.slug), params: {
          organization_invitation: {
            email_address: "admin-invites-#{role}@example.test",
            organization_role: role
          }
        }
      end
      assert_response :see_other
    end

    %w[owner billing].each do |role|
      assert_no_difference -> { OrganizationInvitation.count } do
        post organization_invitations_path(organization_slug: @organization.slug), params: {
          organization_invitation: {
            email_address: "admin-denied-#{role}@example.test",
            organization_role: role
          }
        }
      end
      assert_response :forbidden
    end
  end

  test "billing and member roles cannot create invitations through direct requests" do
    %i[billing member].each do |role|
      actor = create_test_user(email_address: "invitation-#{role}@example.test")
      actor_membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: role
      )
      create_locator_for(actor_membership)
      sign_in_as(actor)

      assert_no_difference -> { OrganizationInvitation.count } do
        post organization_invitations_path(organization_slug: @organization.slug), params: {
          organization_invitation: {
            email_address: "denied-by-#{role}@example.test",
            organization_role: "member"
          }
        }
      end
      assert_response :forbidden

      delete session_path
    end
  end

  test "resend rotates the token and revoke prevents acceptance" do
    result = create_pending_invitation(email_address: "resend@example.test")
    invitation = result.fetch(:invitation)
    old_token = result.fetch(:raw_token)
    sign_in_as(@owner)

    assert_emails 1 do
      post resend_organization_invitation_path(
        organization_slug: @organization.slug,
        id: invitation.id
      )
    end

    new_token = token_from_last_invitation_email
    assert_response :see_other
    assert_not_equal old_token, new_token
    assert_equal OrganizationInvitation.digest_token(new_token), invitation.reload.token_digest

    patch revoke_organization_invitation_path(
      organization_slug: @organization.slug,
      id: invitation.id
    )

    assert_response :see_other
    assert_predicate invitation.reload, :revoked?
    assert_not_nil invitation.revoked_at
  end

  test "resend and revoke races return safe redirects" do
    recipient = create_test_user(email_address: "resend-race@example.test")
    invitation = create_pending_invitation(email_address: recipient.email_address).fetch(:invitation)
    create_test_membership(
      organization: @organization,
      user: recipient,
      role: :member
    )
    expired_invitation = create_pending_invitation(
      email_address: "elapsed-revoke@example.test"
    ).fetch(:invitation)
    expired_resend = create_pending_invitation(
      email_address: "elapsed-resend@example.test"
    ).fetch(:invitation)
    sign_in_as(@owner)

    assert_no_emails do
      post resend_organization_invitation_path(
        organization_slug: @organization.slug,
        id: invitation.id
      )
    end
    assert_response :see_other
    assert_match(/active organization member/i, flash[:alert])
    assert_predicate invitation.reload, :pending?

    travel 8.days do
      assert_no_emails do
        post resend_organization_invitation_path(
          organization_slug: @organization.slug,
          id: expired_resend.id
        )
      end
      assert_response :see_other
      assert_match(/expired/i, flash[:alert])

      patch revoke_organization_invitation_path(
        organization_slug: @organization.slug,
        id: expired_invitation.id
      )
      assert_response :see_other
      assert_equal "Invitation expired.", flash[:notice]
    end
    assert_predicate expired_resend.reload, :expired?
    assert_predicate expired_invitation.reload, :expired?
  end

  test "managed invitation IDs are isolated by Current organization" do
    foreign_owner = create_test_user(email_address: "foreign-invitation-owner@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Invitation Organization",
      slug: "foreign-invitation-organization"
    )
    foreign_invitation = create_invitation_row(
      organization: foreign_organization,
      inviter: foreign_owner,
      email_address: "foreign-invitee@example.test"
    ).fetch(:invitation)
    create_locator_for(foreign_membership)
    sign_in_as(@owner)

    post resend_organization_invitation_path(
      organization_slug: @organization.slug,
      id: foreign_invitation.id
    )
    assert_response :not_found

    patch revoke_organization_invitation_path(
      organization_slug: @organization.slug,
      id: foreign_invitation.id
    )
    assert_response :not_found
    assert_predicate foreign_invitation.reload, :pending?
  end

  test "existing user confirms with GET and accepts with PATCH exactly once" do
    invitee = create_test_user(email_address: "existing-invitee@example.test")
    result = create_pending_invitation(email_address: invitee.email_address, organization_role: :admin)
    invitation = result.fetch(:invitation)
    raw_token = result.fetch(:raw_token)
    sign_in_as(invitee)
    acceptance_path = organization_invitation_acceptance_path(
      organization_slug: @organization.slug,
      token: raw_token
    )
    acceptance_update_path = organization_invitation_acceptance_path(
      organization_slug: @organization.slug
    )

    assert_no_difference [
      -> { @organization.organization_memberships.count },
      -> { @organization.organization_access_locators.count }
    ] do
      get acceptance_path
    end

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_select "h1", text: /Join Invitation Request Organization/
    assert_select "nav[aria-label='Organization navigation']", count: 0
    assert_select "form[action=?]", organization_invitation_acceptance_path(
      organization_slug: @organization.slug
    )
    assert_select "input[name='token'][value=?]", raw_token
    assert_difference [
      -> { @organization.organization_memberships.count },
      -> { @organization.organization_access_locators.count }
    ], 1 do
      patch acceptance_update_path, params: { token: raw_token }
    end

    assert_response :see_other
    assert_redirected_to organization_dashboard_path(organization_slug: @organization.slug)
    assert_predicate invitation.reload, :accepted?
    assert_not_nil invitation.accepted_at
    membership = @organization.organization_memberships.find_by!(user: invitee)
    assert_predicate membership, :admin?

    assert_no_difference [
      -> { @organization.organization_memberships.count },
      -> { @organization.organization_access_locators.count }
    ] do
      patch acceptance_update_path, params: { token: raw_token }
    end
    assert_response :not_found
  end

  test "new user registers and verifies without storing the raw invitation token in the session" do
    email_address = "new-registration-invitee@example.test"
    result = create_pending_invitation(email_address: email_address)
    raw_token = result.fetch(:raw_token)
    acceptance_path = organization_invitation_acceptance_path(
      organization_slug: @organization.slug,
      token: raw_token
    )
    acceptance_update_path = organization_invitation_acceptance_path(
      organization_slug: @organization.slug
    )

    get acceptance_path
    assert_redirected_to new_session_path
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_nil request.session[:return_to_after_authenticating]
    assert_equal Organizations::InvitationAcceptancesController::AUTHENTICATION_NOTICE, flash[:alert]

    post registration_path, params: {
      user: {
        name: "New Invitation User",
        email_address: email_address,
        password: INVITEE_PASSWORD,
        password_confirmation: INVITEE_PASSWORD
      }
    }
    user = User.find_by!(email_address: email_address)
    verification_token = user.email_verification_token

    patch email_verification_path, params: { token: verification_token }

    assert_redirected_to new_session_path
    assert_equal new_organization_path, request.session[:return_to_after_authenticating]

    post session_path, params: {
      email_address: email_address,
      password: INVITEE_PASSWORD
    }
    assert_redirected_to new_organization_path

    get acceptance_path
    assert_response :success
    patch acceptance_update_path, params: { token: raw_token }

    assert_response :see_other
    assert @organization.organization_memberships.active.exists?(user_id: user.id)
  end

  test "invalid expired revoked used wrong-email and wrong-slug links share not-found behavior" do
    invitee = create_test_user(email_address: "edge-invitee@example.test")
    wrong_user = create_test_user(email_address: "wrong-edge-invitee@example.test")
    result = create_pending_invitation(email_address: invitee.email_address)
    invitation = result.fetch(:invitation)
    raw_token = result.fetch(:raw_token)

    sign_in_as(wrong_user)
    assert_invalid_invitation(raw_token: raw_token)
    delete session_path

    sign_in_as(invitee)
    assert_invalid_invitation(raw_token: "unknown-token")

    other_owner = create_test_user(email_address: "other-slug-owner@example.test")
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Slug Organization",
      slug: "other-slug-organization"
    )
    get organization_invitation_acceptance_path(
      organization_slug: other_organization.slug,
      token: raw_token
    )
    assert_generic_invitation_not_found
    assert_no_match other_organization.name, response.body

    travel 8.days do
      assert_invalid_invitation(raw_token: raw_token)
    end

    invitation.update_columns(
      status: "revoked",
      revoked_at: Time.current,
      updated_at: Time.current
    )
    assert_invalid_invitation(raw_token: raw_token)

    invitation.update_columns(
      status: "accepted",
      accepted_at: Time.current,
      revoked_at: nil,
      updated_at: Time.current
    )
    assert_invalid_invitation(raw_token: raw_token)
  end

  test "invitation creation is rate limited per actor and organization" do
    sign_in_as(@owner)
    invitation_params = {
      organization_invitation: {
        email_address: "rate-limited-invitation@example.test",
        organization_role: "member"
      }
    }

    10.times do
      post organization_invitations_path(organization_slug: @organization.slug),
        params: invitation_params
      assert_response :see_other
    end

    assert_no_difference -> { OrganizationInvitation.count } do
      assert_no_emails do
        post organization_invitations_path(organization_slug: @organization.slug),
          params: invitation_params
      end
    end

    assert_response :see_other
    assert_equal "Please wait before sending another invitation.", flash[:alert]
  end

  test "resend is rate limited without rotating or delivering an eleventh token" do
    invitation = create_pending_invitation(
      email_address: "rate-limited-resend@example.test"
    ).fetch(:invitation)
    sign_in_as(@owner)

    10.times do
      assert_emails 1 do
        post resend_organization_invitation_path(
          organization_slug: @organization.slug,
          id: invitation.id
        )
      end
      assert_response :see_other
    end
    digest_after_tenth_delivery = invitation.reload.token_digest

    assert_no_emails do
      post resend_organization_invitation_path(
        organization_slug: @organization.slug,
        id: invitation.id
      )
    end

    assert_response :see_other
    assert_equal "Please wait before sending another invitation.", flash[:alert]
    assert_equal digest_after_tenth_delivery, invitation.reload.token_digest
  end

  test "acceptance rate limit runs before invitation lookup" do
    invitee = create_test_user(email_address: "acceptance-rate-limit@example.test")
    sign_in_as(invitee)
    acceptance_path = organization_invitation_acceptance_path(
      organization_slug: @organization.slug
    )

    10.times do |attempt|
      patch acceptance_path, params: { token: "invalid-token-#{attempt}" }
      assert_response :not_found
    end

    invitation_queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      invitation_queries << payload[:sql] if payload[:sql].include?("organization_invitations")
    end
    patch acceptance_path, params: { token: "eleventh-invalid-token" }

    assert_response :not_found
    assert_empty invitation_queries
    ActiveSupport::Notifications.unsubscribe(subscription)
    subscription = nil

    delete session_path
    other_user = create_test_user(email_address: "other-acceptance-rate-limit@example.test")
    sign_in_as(other_user)
    other_user_queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      other_user_queries << payload[:sql] if payload[:sql].include?("organization_invitations")
    end
    patch acceptance_path, params: { token: "other-user-invalid-token" }

    assert_response :not_found
    assert_not_empty other_user_queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "acceptance mutation requires a CSRF token when forgery protection is enabled" do
    invitee = create_test_user(email_address: "csrf-invitee@example.test")
    result = create_pending_invitation(email_address: invitee.email_address)
    invitation = result.fetch(:invitation)
    sign_in_as(invitee)
    original_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference -> { @organization.organization_memberships.count } do
      patch organization_invitation_acceptance_path(organization_slug: @organization.slug),
        params: { token: result.fetch(:raw_token) }
    end

    assert_response :unprocessable_content
    assert_predicate invitation.reload, :pending?
  ensure
    ActionController::Base.allow_forgery_protection = original_setting
  end

  private
    def create_pending_invitation(email_address:, organization_role: :member)
      create_invitation_row(
        organization: @organization,
        inviter: @owner,
        email_address: email_address,
        organization_role: organization_role
      )
    end

    def create_invitation_row(
      organization:,
      inviter:,
      email_address:,
      organization_role: :member,
      expires_at: 7.days.from_now
    )
      raw_token = SecureRandom.urlsafe_base64(32)
      invitation = organization.organization_invitations.create!(
        inviter: inviter,
        email_address: email_address,
        organization_role: organization_role,
        status: :pending,
        token_digest: OrganizationInvitation.digest_token(raw_token),
        expires_at: expires_at
      )
      { invitation: invitation, raw_token: raw_token }
    end

    def create_locator_for(membership)
      OrganizationAccessLocator.find_or_create_by!(
        organization_membership: membership,
        user: membership.user,
        organization: membership.organization
      )
    end

    def token_from_last_invitation_email
      email = ActionMailer::Base.deliveries.reverse.find do |message|
        message.subject.start_with?("You're invited to")
      end
      assert_not_nil email

      URI.parse(URI.extract(email.text_part.body.to_s, %w[http https]).first)
        .then { |uri| Rack::Utils.parse_nested_query(uri.query).fetch("token") }
    end

    def assert_invalid_invitation(raw_token:)
      get organization_invitation_acceptance_path(
        organization_slug: @organization.slug,
        token: raw_token
      )
      assert_generic_invitation_not_found
    end

    def assert_generic_invitation_not_found
      assert_response :not_found
      assert_select "title", "Page not found (404)"
      assert_no_match @organization.name, response.body
    end
end
