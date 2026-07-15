require "test_helper"
require_relative "../../db/migrate/20260715170300_create_organization_access_locators"
require_relative "../support/organization_test_helper"

class CreateOrganizationAccessLocatorsTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  test "verification fails closed when an active membership has no exact locator" do
    owner = create_test_user(email_address: "locator-verification-owner@example.test")
    create_test_organization_with_owner(owner: owner)
    migration = CreateOrganizationAccessLocators.new

    error = assert_raises(ActiveRecord::MigrationError) do
      migration.suppress_messages do
        migration.send(:verify_active_membership_backfill!)
      end
    end

    assert_match(/incomplete for 1 active memberships/, error.message)
  end

  test "backfill is idempotent and creates locators only for active memberships" do
    owner = create_test_user(email_address: "locator-backfill-owner@example.test")
    active_user = create_test_user(email_address: "locator-backfill-active@example.test")
    suspended_user = create_test_user(email_address: "locator-backfill-suspended@example.test")
    organization, owner_membership = create_test_organization_with_owner(owner: owner)
    active_membership = create_test_membership(
      organization: organization,
      user: active_user,
      role: :member
    )
    suspended_membership = create_test_membership(
      organization: organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )
    migration = CreateOrganizationAccessLocators.new

    assert_difference -> { OrganizationAccessLocator.count }, 2 do
      migration.suppress_messages do
        migration.send(:backfill_active_memberships)
        migration.send(:backfill_active_memberships)
        migration.send(:verify_active_membership_backfill!)
      end
    end

    assert OrganizationAccessLocator.exists?(organization_membership_id: owner_membership.id)
    assert OrganizationAccessLocator.exists?(organization_membership_id: active_membership.id)
    assert_not OrganizationAccessLocator.exists?(organization_membership_id: suspended_membership.id)
  end
end
