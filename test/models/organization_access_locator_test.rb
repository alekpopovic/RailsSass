require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationAccessLocatorTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "locator-owner@example.test")
    @user = create_test_user(email_address: "locator-member@example.test")
    @organization, = create_test_organization_with_owner(owner: @owner)
    @membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :member
    )
  end

  test "belongs to one matching active membership user and organization" do
    locator = create_locator

    assert_equal @membership, locator.organization_membership
    assert_equal @user, locator.user
    assert_equal @organization, locator.organization
    assert_equal locator, @membership.organization_access_locator
    assert_includes @user.organization_access_locators, locator
    assert_includes @organization.organization_access_locators, locator
  end

  test "rejects a suspended membership" do
    OrganizationMembership.where(id: @membership.id).update_all(status: "suspended")
    @membership.reload

    locator = OrganizationAccessLocator.new(
      organization_membership: @membership,
      user: @user,
      organization: @organization
    )

    assert_not locator.valid?
    assert_includes locator.errors[:organization_membership], "must be active"
  end

  test "rejects a membership identity mismatch" do
    other_user = create_test_user(email_address: "locator-other-user@example.test")
    locator = OrganizationAccessLocator.new(
      organization_membership: @membership,
      user: other_user,
      organization: @organization
    )

    assert_not locator.valid?
    assert_includes locator.errors[:organization_membership], "must match the user and organization"
  end

  test "database enforces one locator per membership and user organization pair" do
    locator = create_locator

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      OrganizationAccessLocator.insert_all!([ raw_attributes(
        organization_membership_id: locator.organization_membership_id
      ) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database defines both locator identity unique indexes" do
    unique_indexes = OrganizationAccessLocator.connection
      .indexes(:organization_access_locators)
      .select(&:unique)
      .map(&:columns)

    assert_includes unique_indexes, [ "organization_membership_id" ]
    assert_includes unique_indexes, [ "user_id", "organization_id" ]
  end

  test "database requires every locator identity and timestamp" do
    required_columns = %w[
      organization_membership_id
      user_id
      organization_id
      created_at
      updated_at
    ]
    columns = OrganizationAccessLocator.columns.index_by(&:name)

    required_columns.each do |column_name|
      assert_not columns.fetch(column_name).null, "expected #{column_name} to be NOT NULL"
    end
  end

  test "database foreign key rejects an unknown organization" do
    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationAccessLocator.insert_all!([ raw_attributes(organization_id: -1) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database foreign key rejects an unknown user" do
    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationAccessLocator.insert_all!([ raw_attributes(user_id: -1) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database composite foreign key rejects a mismatched membership identity" do
    other_user = create_test_user(email_address: "locator-fk-user@example.test")

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationAccessLocator.insert_all!([ raw_attributes(user_id: other_user.id) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database defines restricted organization user and composite membership foreign keys" do
    foreign_keys = OrganizationAccessLocator.connection.foreign_keys(:organization_access_locators)

    assert foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "organizations" &&
        foreign_key.column == "organization_id" &&
        foreign_key.on_delete == :restrict
    }
    assert foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "users" &&
        foreign_key.column == "user_id" &&
        foreign_key.on_delete == :restrict
    }
    assert foreign_keys.any? { |foreign_key|
      foreign_key.to_table == "organization_memberships" &&
        foreign_key.column == %w[organization_membership_id user_id organization_id] &&
        foreign_key.primary_key == %w[id user_id organization_id] &&
        foreign_key.on_delete == :restrict
    }
  end

  test "database restricts deleting referenced membership history" do
    create_locator

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationMembership.where(id: @membership.id).delete_all
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database restricts deleting a referenced organization root" do
    create_locator

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      Organization.where(id: @organization.id).delete_all
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database restricts deleting a referenced user root" do
    create_locator

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      User.where(id: @user.id).delete_all
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "locator identity cannot be changed after creation" do
    locator = create_locator

    %i[organization_membership_id user_id organization_id].each do |attribute|
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        locator.update!(attribute => -1)
      end
    end
  end

  private
    def create_locator
      OrganizationAccessLocator.create!(
        organization_membership: @membership,
        user: @user,
        organization: @organization
      )
    end

    def raw_attributes(**overrides)
      {
        organization_membership_id: @membership.id,
        user_id: @user.id,
        organization_id: @organization.id,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end
end
