require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "organization-model-owner@example.test")
  end

  test "normalizes attributes and assigns a public UUID and active status" do
    organization = create_organization!(name: "  Example Organization  ", slug: " Example_ORG ")

    assert_equal "Example Organization", organization.name
    assert_equal "example-org", organization.slug
    assert_match(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/, organization.public_id)
    assert_predicate organization, :active?
  end

  test "validates normalized slug uniqueness" do
    create_organization!(name: "First Organization", slug: "example-org")
    duplicate = Organization.new(name: "Duplicate Organization", slug: " EXAMPLE ORG ")

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:slug, :taken)
  end

  test "database enforces public id uniqueness" do
    organization = create_organization!(name: "Unique Organization", slug: "unique-organization")

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      Organization.insert_all!([ raw_attributes(
        public_id: organization.public_id,
        slug: "another-organization"
      ) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database enforces slug uniqueness" do
    organization = create_organization!(name: "Unique Organization", slug: "unique-organization")

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      Organization.insert_all!([ raw_attributes(slug: organization.slug) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database rejects a non-normalized name" do
    organization = create_organization!(name: "Normalized Organization", slug: "normalized-organization")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Organization.connection.execute(
        "UPDATE organizations SET name = ' Padded Organization ' WHERE id = #{organization.id}"
      )
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects a malformed slug" do
    organization = create_organization!(name: "Slug Organization", slug: "slug-organization")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Organization.connection.execute(
        "UPDATE organizations SET slug = 'Invalid_Slug' WHERE id = #{organization.id}"
      )
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects an unsupported status" do
    organization = create_organization!(name: "Status Organization", slug: "status-organization")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Organization.connection.execute(
        "UPDATE organizations SET status = 'archived' WHERE id = #{organization.id}"
      )
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects missing required organization values" do
    error = assert_raises(ActiveRecord::NotNullViolation) do
      Organization.insert_all!([ raw_attributes(name: nil) ])
    end

    assert_kind_of PG::NotNullViolation, error.cause
  end

  test "database rejects a missing public id" do
    error = assert_raises(ActiveRecord::NotNullViolation) do
      Organization.insert_all!([ raw_attributes(public_id: nil) ])
    end

    assert_kind_of PG::NotNullViolation, error.cause
  end

  test "public id and slug cannot be changed after creation" do
    organization = create_organization!(name: "Immutable Organization", slug: "immutable-organization")

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      organization.update!(public_id: SecureRandom.uuid)
    end
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      organization.update!(slug: "changed-organization")
    end
  end

  test "database rejects committing an organization without an active owner" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      Organization.transaction(requires_new: true) do
        Organization.create!(name: "Ownerless Organization", slug: "ownerless-organization")
        Organization.connection.execute(
          "SET CONSTRAINTS organization_must_have_active_owner IMMEDIATE"
        )
      end
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  private
    def create_organization!(**attributes)
      organization = nil

      Organization.transaction do
        organization = Organization.create!(**attributes)
        create_test_membership(
          organization: organization,
          user: @owner,
          role: :owner
        )
      end

      organization
    end

    def raw_attributes(**overrides)
      {
        public_id: SecureRandom.uuid,
        name: "Database Organization",
        slug: "database-organization-#{SecureRandom.hex(4)}",
        status: "active",
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end
end
