require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  setup do
    user = User.create!(
      name: "Current User",
      email_address: "current-user@example.test",
      password: "correct horse battery staple",
      password_confirmation: "correct horse battery staple",
      email_verified_at: Time.current
    )
    @session, = Session.issue_for!(user, ip_address: nil, user_agent: nil)
  end

  teardown do
    Current.reset
  end

  test "delegates the user through the current session" do
    Current.session = @session

    assert_equal @session, Current.session
    assert_equal @session.user, Current.user
  end

  test "exposes canonical membership context through the compatibility name" do
    membership = OrganizationMembership.new(role: :owner, joined_at: Time.current)

    Current.organization_membership = membership

    assert_same membership, Current.membership
    assert_same membership, Current.organization_membership
  end

  test "supports the compatibility name in scoped Current context" do
    membership = OrganizationMembership.new(role: :owner, joined_at: Time.current)

    Current.set(organization_membership: membership) do
      assert_same membership, Current.membership
      assert_same membership, Current.organization_membership
    end

    assert_nil Current.membership
  end

  test "reset clears session, user, and tenant context" do
    Current.session = @session
    Current.organization = Organization.new(name: "Current Organization", slug: "current-organization")
    Current.membership = OrganizationMembership.new(role: :owner, joined_at: Time.current)

    Current.reset

    assert_nil Current.session
    assert_nil Current.user
    assert_nil Current.organization
    assert_nil Current.membership
    assert_nil Current.organization_membership
  end
end
