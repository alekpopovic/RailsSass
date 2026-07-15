require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationsRequestTest < ActionDispatch::IntegrationTest
  include OrganizationTestHelper

  test "onboarding requires authentication and stores only a safe GET destination" do
    user = create_test_user(email_address: "onboarding-login@example.test")

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      get new_organization_path
    end
    assert_redirected_to new_session_path

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }

    assert_redirected_to new_organization_path

    delete session_path

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      post organizations_path, params: {
        organization: { name: "Unauthorized", slug: "unauthorized" }
      }
    end
    assert_redirected_to new_session_path
  end

  test "authenticated onboarding creates only server-owned owner membership attributes" do
    user = create_test_user(email_address: "onboarding-owner@example.test")
    other_user = create_test_user(email_address: "untrusted-user@example.test")
    untrusted_public_id = SecureRandom.uuid
    sign_in_as(user)

    assert_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ], 1 do
      post organizations_path, params: {
        organization: {
          name: "  Onboarding Company  ",
          slug: " Onboarding Company ",
          public_id: untrusted_public_id,
          status: "suspended",
          user_id: other_user.id,
          role: "member",
          joined_at: 10.years.ago
        }
      }
    end

    organization = Organization.find_by!(slug: "onboarding-company")
    membership = organization.organization_memberships.sole

    assert_equal "Onboarding Company", organization.name
    assert_not_equal untrusted_public_id, organization.public_id
    assert_predicate organization, :active?
    assert_equal user, membership.user
    assert_predicate membership, :owner?
    assert_predicate membership, :active?
    assert_in_delta Time.current, membership.joined_at, 1.second
    assert_redirected_to organization_dashboard_path(organization_slug: organization.slug)
    assert_equal "Your organization has been created.", flash[:notice]
    assert_nil Current.organization
    assert_nil Current.membership
    assert_nil Current.organization_membership
  end

  test "an authenticated session cannot onboard after its user is disabled" do
    user = create_test_user(email_address: "disabled-onboarding@example.test")
    session_record = sign_in_as(user)
    user.update!(disabled_at: Time.current)

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      post organizations_path, params: {
        organization: { name: "Denied Organization", slug: "denied-organization" }
      }
    end

    assert_redirected_to new_session_path
    assert_not Session.exists?(session_record.id)
  end

  test "an authenticated session cannot onboard after its email becomes unverified" do
    user = create_test_user(email_address: "unverified-onboarding@example.test")
    session_record = sign_in_as(user)
    User.find(user.id).update!(email_address: "changed-unverified-onboarding@example.test")

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      post organizations_path, params: {
        organization: { name: "Denied Organization", slug: "unverified-denied-organization" }
      }
    end

    assert_redirected_to new_session_path
    assert_not Session.exists?(session_record.id)
  end

  test "invalid onboarding rolls back both records and renders accessible errors" do
    user = create_test_user(email_address: "invalid-onboarding@example.test")
    sign_in_as(user)

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      post organizations_path, params: {
        organization: { name: "", slug: "" }
      }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']"
    assert_select "form[action=?]", organizations_path
  end

  test "duplicate normalized slug creates no partial membership" do
    existing_owner = create_test_user(email_address: "existing-owner@example.test")
    create_test_organization_with_owner(
      owner: existing_owner,
      name: "Existing",
      slug: "existing-organization"
    )
    user = create_test_user(email_address: "duplicate-slug@example.test")
    sign_in_as(user)

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      post organizations_path, params: {
        organization: { name: "Duplicate", slug: " Existing Organization " }
      }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /Slug has already been taken/
  end
end
