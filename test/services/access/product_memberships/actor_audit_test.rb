require "test_helper"
require_relative "support"
require_relative "../../../support/catalog_test_helper"

class Access::ProductMemberships::ActorAuditTest < ActiveSupport::TestCase
  include AccessProductMembershipsTestSupport
  include CatalogTestHelper

  setup do
    create_access_test_records
    @plan = create_test_plan(free: true)
    @plan_product = create_test_plan_product(plan: @plan, product: @product)
    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
  end

  teardown do
    Current.reset
  end

  test "actor-backed lifecycle and role changes emit tenant audit events" do
    product_membership = Access::ProductMemberships::Add.new(
      organization_membership_id: @organization_membership.id,
      product_id: @product.id,
      actor: @owner
    ).call
    Access::ProductMemberships::Add.new(
      organization_membership_id: @organization_membership.id,
      product_id: @product.id,
      actor: @owner
    ).call
    role = create_access_test_role

    Access::ProductMemberships::AssignRole.new(
      product_membership_id: product_membership.id,
      product_role_id: role.id,
      actor: @owner
    ).call
    Access::ProductMemberships::AssignRole.new(
      product_membership_id: product_membership.id,
      product_role_id: role.id,
      actor: @owner
    ).call
    Access::ProductMemberships::UnassignRole.new(
      product_membership_id: product_membership.id,
      product_role_id: role.id,
      actor: @owner
    ).call
    Access::ProductMemberships::Suspend.new(
      product_membership_id: product_membership.id,
      actor: @owner
    ).call
    Access::ProductMemberships::Suspend.new(
      product_membership_id: product_membership.id,
      actor: @owner
    ).call
    Access::ProductMemberships::Reactivate.new(
      product_membership_id: product_membership.id,
      actor: @owner
    ).call
    Access::ProductMemberships::Reactivate.new(
      product_membership_id: product_membership.id,
      actor: @owner
    ).call
    Access::ProductMemberships::Remove.new(
      product_membership_id: product_membership.id,
      actor: @owner
    ).call

    events = @organization.audit_events.order(:id)
    assert_equal %w[
      product.membership.created
      product.membership.role_assigned
      product.membership.role_unassigned
      product.membership.suspended
      product.membership.reactivated
      product.membership.removed
    ], events.pluck(:action)
    assert_equal [ @owner.id ], events.reorder(nil).distinct.pluck(:actor_user_id)
    assert_equal [ product_membership.id ], events.reorder(nil).distinct.pluck(:subject_id)
    assert_equal [ "ProductMembership" ], events.reorder(nil).distinct.pluck(:subject_type)
    assert_equal({
      "membership_id" => @organization_membership.id,
      "product_key" => @product.key
    }, events.first.metadata)
    assert_equal role.key, events.second.metadata.fetch("product_role_key")
    assert_equal role.key, events.third.metadata.fetch("product_role_key")
  end

  test "legacy calls without an actor preserve behavior without fabricating audit events" do
    assert_no_difference -> { @organization.audit_events.count } do
      product_membership = add_product_membership
      role = create_access_test_role
      assignment = assign_product_role(
        product_membership: product_membership,
        product_role: role
      )

      removed_assignment = Access::ProductMemberships::UnassignRole.new(
        product_membership_id: product_membership.id,
        product_role_id: role.id
      ).call

      assert_equal assignment.id, removed_assignment.id
      assert_predicate removed_assignment, :destroyed?
    end
  end

  test "a live organization admin may perform an audited product assignment" do
    admin = create_test_user(email_address: "product-access-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    establish_tenant_context(
      user: admin,
      organization: @organization,
      membership: admin_membership
    )

    product_membership = add_with_actor(admin)
    event = @organization.audit_events.find_by!(action: "product.membership.created")

    assert_equal @organization.id, product_membership.organization_id
    assert_equal admin.id, event.actor_user_id
  end

  test "actor is revalidated as a live owner or admin with a product entitlement" do
    denied_actors = [ [ @member, @organization_membership ] ]
    billing_user = create_test_user(email_address: "product-access-billing@example.test")
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :billing
    )
    denied_actors << [ billing_user, billing_membership ]

    denied_actors.each do |actor, membership|
      establish_tenant_context(
        user: actor,
        organization: @organization,
        membership: membership
      )

      assert_no_difference [
        -> { @organization.product_memberships.count },
        -> { @organization.audit_events.count }
      ] do
        assert_raises(Pundit::NotAuthorizedError) do
          add_with_actor(actor)
        end
      end
    end

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    Session.where(id: Current.session.id).delete_all

    assert_no_difference [
      -> { @organization.product_memberships.count },
      -> { @organization.audit_events.count }
    ] do
      assert_raises(Pundit::NotAuthorizedError) do
        add_with_actor(@owner)
      end
    end

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    @plan_product.destroy!

    assert_no_difference [
      -> { @organization.product_memberships.count },
      -> { @organization.audit_events.count }
    ] do
      assert_raises(Pundit::NotAuthorizedError) do
        add_with_actor(@owner)
      end
    end
  end

  test "an audit failure rolls back the product membership mutation" do
    failing_service = Class.new(Access::ProductMemberships::Add) do
      private
        def record_audit_event!(**)
          raise ActiveRecord::ActiveRecordError, "synthetic audit failure"
        end
    end

    assert_no_difference [
      -> { @organization.product_memberships.count },
      -> { @organization.audit_events.count }
    ] do
      error = assert_raises(ActiveRecord::ActiveRecordError) do
        failing_service.new(
          organization_membership_id: @organization_membership.id,
          product_id: @product.id,
          actor: @owner
        ).call
      end
      assert_equal "synthetic audit failure", error.message
    end
  end

  private
    def add_with_actor(actor)
      Access::ProductMemberships::Add.new(
        organization_membership_id: @organization_membership.id,
        product_id: @product.id,
        actor: actor
      ).call
    end
end
