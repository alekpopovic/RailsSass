require "test_helper"
require_relative "../../support/organization_test_helper"

class AuditEvents::RecordTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "audit-service-owner@example.test")
    @organization, = create_test_organization_with_owner(owner: @owner)
  end

  test "records a tenant-rooted append-only event" do
    event = AuditEvents::Record.call(
      organization: @organization,
      actor_user: @owner,
      action: "organization.created",
      subject: @organization,
      request_id: "request-123",
      metadata: { public_id: @organization.public_id }
    )

    assert_equal @organization, event.organization
    assert_equal @owner, event.actor_user
    assert_equal "Organization", event.subject_type
    assert_equal @organization.id, event.subject_id
    assert_equal "request-123", event.request_id
    assert_equal({ "public_id" => @organization.public_id }, event.metadata)
    assert_predicate event, :readonly?
  end

  test "supports a system actor and job correlation" do
    event = AuditEvents::Record.call(
      organization: @organization,
      actor_user: nil,
      action: "system.reconciled",
      subject: @organization,
      job_id: "job-123"
    )

    assert_nil event.actor_user
    assert_equal "job-123", event.job_id
  end

  test "accepts allowlisted stable product and product role keys" do
    product = Product.create!(
      key: "audit_product",
      name: "Audit Product",
      description: "Synthetic audit metadata product."
    )
    product_membership = @organization.product_memberships.create!(
      organization_membership: @organization.organization_memberships.find_by!(user: @owner),
      product: product
    )

    event = AuditEvents::Record.call(
      organization: @organization,
      actor_user: @owner,
      action: "product.membership.role_assigned",
      subject: product_membership,
      metadata: {
        membership_id: product_membership.organization_membership_id,
        product_key: product.key,
        product_role_key: "product_admin"
      }
    )

    assert_equal "audit_product", event.metadata.fetch("product_key")
    assert_equal "product_admin", event.metadata.fetch("product_role_key")
  end

  test "rejects sensitive or non-allowlisted metadata keys and values" do
    [
      { email_address: "hidden@example.test" },
      { nested: { invitation_token: "hidden" } },
      { target: "hidden@example.test" },
      { value: SecureRandom.urlsafe_base64(32) },
      { membership_id: "123" },
      { organization_role: "super_owner" },
      { product_key: "Invalid Product" },
      { product_role_key: "viewer;delete" }
    ].each do |metadata|
      assert_raises(ArgumentError) do
        AuditEvents::Record.call(
          organization: @organization,
          actor_user: @owner,
          action: "invitation.created",
          subject: @organization,
          metadata: metadata
        )
      end
    end

    assert_empty @organization.audit_events
  end

  test "rejects a subject owned by another organization" do
    other_owner = create_test_user(email_address: "other-audit-subject-owner@example.test")
    other_organization, other_membership = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Audit Subject Organization",
      slug: "other-audit-subject-organization"
    )

    assert_no_difference -> { @organization.audit_events.count } do
      assert_raises(ArgumentError) do
        AuditEvents::Record.call(
          organization: @organization,
          actor_user: @owner,
          action: "organization.membership.created",
          subject: other_membership,
          metadata: { organization_role: "owner" }
        )
      end
    end

    assert_equal other_organization.id, other_membership.organization_id
  end

  test "requires persisted tenant and subject records" do
    assert_raises(ArgumentError) do
      AuditEvents::Record.call(
        organization: Organization.new,
        actor_user: @owner,
        action: "organization.created",
        subject: @organization
      )
    end

    assert_raises(ArgumentError) do
      AuditEvents::Record.call(
        organization: @organization,
        actor_user: @owner,
        action: "organization.created",
        subject: Organization.new
      )
    end
  end
end
