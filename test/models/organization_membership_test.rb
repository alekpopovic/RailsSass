require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationMembershipTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @founding_owner = create_test_user(email_address: "founding-owner@example.test")
    @user = create_test_user
    @organization, @founding_membership = create_test_organization_with_owner(
      owner: @founding_owner
    )
  end

  test "supports the organization role and status allowlists" do
    membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :owner
    )

    assert_predicate membership, :owner?
    assert_predicate membership, :active?
    assert_includes OrganizationMembership.roles.keys, "billing"
    assert_includes OrganizationMembership.statuses.keys, "suspended"
  end

  test "an active owner remains part of the database invariant when its user is disabled" do
    @founding_owner.update!(disabled_at: Time.current)

    assert_equal [ @founding_membership ], @organization.organization_memberships.active_owners.to_a
    assert_empty @organization.organization_memberships.eligible_owners
  end

  test "database enforces membership uniqueness" do
    create_test_membership(organization: @organization, user: @user, role: :member)

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      OrganizationMembership.insert_all!([ raw_attributes ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database rejects an invalid role" do
    membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :member
    )

    error = assert_raises(ActiveRecord::StatementInvalid) do
      OrganizationMembership.connection.execute(
        "UPDATE organization_memberships SET role = 'super_owner' WHERE id = #{membership.id}"
      )
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects an invalid status" do
    membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :member
    )

    error = assert_raises(ActiveRecord::StatementInvalid) do
      OrganizationMembership.connection.execute(
        "UPDATE organization_memberships SET status = 'removed' WHERE id = #{membership.id}"
      )
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects a missing joined at" do
    error = assert_raises(ActiveRecord::NotNullViolation) do
      OrganizationMembership.insert_all!([ raw_attributes(joined_at: nil) ])
    end

    assert_kind_of PG::NotNullViolation, error.cause
  end

  test "database foreign key rejects an unknown organization" do
    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationMembership.insert_all!([ raw_attributes(organization_id: -1) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database foreign key rejects an unknown user" do
    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationMembership.insert_all!([ raw_attributes(user_id: -1) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database restricts deleting an organization with membership history" do
    create_test_membership(organization: @organization, user: @user, role: :owner)

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      Organization.where(id: @organization.id).delete_all
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database restricts deleting a user with membership history" do
    create_test_membership(organization: @organization, user: @user, role: :owner)

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      User.where(id: @user.id).delete_all
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "identity role status and join time are immutable outside lifecycle services" do
    membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :member
    )

    %i[organization_id user_id role status joined_at].each do |attribute|
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        membership.update!(attribute => replacement_for(attribute))
      end
    end
  end

  test "database rejects deleting the last active owner" do
    organization, membership = create_sole_owner_organization

    error = assert_active_owner_constraint do
      membership.delete
    end

    assert_kind_of PG::CheckViolation, error.cause
    assert organization.organization_memberships.active_owners.exists?(membership.id)
  end

  test "database rejects demoting or suspending the last active owner" do
    organization, membership = create_sole_owner_organization

    [ { role: "member" }, { status: "suspended" } ].each do |transition|
      error = assert_active_owner_constraint do
        organization.organization_memberships.where(id: membership.id).update_all(transition)
      end

      assert_kind_of PG::CheckViolation, error.cause
      assert organization.organization_memberships.active_owners.exists?(membership.id)
    end
  end

  private
    def assert_active_owner_constraint(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        OrganizationMembership.transaction(requires_new: true) do
          block.call
          OrganizationMembership.connection.execute(
            "SET CONSTRAINTS organization_must_have_active_owner IMMEDIATE"
          )
        end
      end
    end

    def create_sole_owner_organization
      suffix = SecureRandom.hex(4)
      owner = create_test_user(email_address: "sole-owner-#{suffix}@example.test")

      organization, membership = create_test_organization_with_owner(
        owner: owner,
        name: "Sole Owner Organization",
        slug: "sole-owner-#{suffix}"
      )

      [ organization, membership ]
    end

    def raw_attributes(**overrides)
      {
        organization_id: @organization.id,
        user_id: @user.id,
        role: "member",
        status: "active",
        joined_at: Time.current,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end

    def replacement_for(attribute)
      {
        organization_id: -1,
        user_id: -1,
        role: "admin",
        status: "suspended",
        joined_at: 1.day.ago
      }.fetch(attribute)
    end
end
