require "test_helper"
require_relative "../../support/organization_test_helper"

class Organizations::CreateTransactionTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  self.use_transactional_tests = false

  setup do
    @suffix = SecureRandom.hex(6)
    @user = create_test_user(email_address: "commit-owner-#{@suffix}@example.test")
    @session, = Session.issue_for!(@user, ip_address: nil, user_agent: "Commit test")
    Current.session = @session
  end

  teardown do
    Current.reset
    Organization.where("slug LIKE ?", "commit-#{@suffix}%").find_each do |organization|
      Current.organization = organization
      Organization.transaction do
        Current.organization.organization_access_locators
          .where(organization_id: Current.organization.id)
          .delete_all
        Current.organization.organization_memberships
          .where(organization_id: Current.organization.id)
          .delete_all
        Current.organization.delete
      end
    end

    Session.where(user_id: @user.id).delete_all
    @user.delete
  ensure
    Current.reset
  end

  test "assigns Current only after the outermost transaction commits" do
    organization = nil

    Organization.transaction do
      organization = create_organization(slug: "commit-#{@suffix}")

      assert_nil Current.organization
      assert_nil Current.membership
    end

    assert_equal organization, Current.organization
    assert_equal organization.organization_memberships.sole, Current.membership
  end

  test "an outer rollback preserves the previous Current context" do
    previous_organization = Organization.new(name: "Previous", slug: "previous")
    previous_membership = OrganizationMembership.new(role: :owner, joined_at: Time.current)
    Current.organization = previous_organization
    Current.membership = previous_membership

    Organization.transaction do
      create_organization(slug: "commit-#{@suffix}-rolled-back")

      assert_equal previous_organization, Current.organization
      assert_equal previous_membership, Current.membership
      raise ActiveRecord::Rollback
    end

    assert_equal previous_organization, Current.organization
    assert_equal previous_membership, Current.membership
    assert_not Organization.exists?(slug: "commit-#{@suffix}-rolled-back")
  end

  private
    def create_organization(slug:)
      Organizations::Create.new(
        user: @user,
        name: "Commit Organization",
        slug: slug
      ).call
    end
end
