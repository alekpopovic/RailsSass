require "test_helper"
require "timeout"
require_relative "support"
require_relative "../../../support/catalog_test_helper"
require_relative "../../../support/audit_event_test_helper"

class Access::ProductMemberships::SeatLimitConcurrencyTest < ActiveSupport::TestCase
  include AccessProductMembershipsTestSupport
  include CatalogTestHelper
  include AuditEventTestHelper

  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @owner = create_test_user(
      email_address: "seat-limit-owner-#{suffix}@example.test"
    )
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Seat Limit #{suffix}",
      slug: "seat-limit-#{suffix}"
    )
    @member = create_test_user(
      email_address: "seat-limit-member-#{suffix}@example.test"
    )
    @member_membership = create_test_membership(
      organization: @organization,
      user: @member,
      role: :member
    )
    @product = create_access_test_product(key: "seat_limit_#{suffix}")
    @seat_limit_feature = create_test_product_feature(
      product: @product,
      key: "seat_limit",
      name: "Product seats",
      kind: :limit
    )
    @plan = active_free_plan
    @plan_product = create_test_plan_product(plan: @plan, product: @product)
    @seat_limit_entitlement = create_test_entitlement(
      plan_product: @plan_product,
      product_feature: @seat_limit_feature,
      limit_value: 1
    )
    @owner_session, = Session.issue_for!(
      @owner,
      ip_address: nil,
      user_agent: "Product seat limit concurrency test"
    )
  end

  teardown do
    Current.reset
    clear_test_audit_events!
    remove_test_records
  ensure
    Current.reset
  end

  test "concurrent owner and member additions consume only one finite product seat" do
    outcomes = run_concurrently(
      [ @owner_membership.id, @member_membership.id ]
    )

    successes = outcomes.grep(ProductMembership)
    denials = outcomes.grep(ActiveRecord::RecordInvalid)

    assert_equal 1, successes.length
    assert_equal 1, denials.length
    assert_instance_of Entitlements::LimitExceeded, denials.first.cause
    assert_equal 1, @organization.product_memberships.where(
      product_id: @product.id,
      status: "active"
    ).count
    assert_includes [ @owner_membership.id, @member_membership.id ],
      successes.first.organization_membership_id
  end

  private
    def active_free_plan
      existing_plan = Plan.find_by(active: true, free: true)
      return existing_plan if existing_plan

      @owns_free_plan = true
      create_test_plan(
        key: unique_catalog_key("seat_limit_free"),
        name: "Seat Limit Free Plan",
        free: true
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      @owns_free_plan = false
      Plan.find_by!(active: true, free: true)
    end

    def run_concurrently(organization_membership_ids)
      ready = Queue.new
      start = Queue.new
      results = Queue.new
      threads = organization_membership_ids.map do |organization_membership_id|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Current.session = Session.includes(:user).find(@owner_session.id)
            Current.organization = Organization.find(@organization.id)
            Current.membership = Current.organization.organization_memberships.find(@owner_membership.id)
            ready << true
            start.pop
            results << Access::ProductMemberships::Add.new(
              organization_membership_id: organization_membership_id,
              product_id: @product.id,
              actor: Current.user
            ).call
          rescue => error
            results << error
          ensure
            Current.reset
          end
        end
      end

      Timeout.timeout(5) { organization_membership_ids.length.times { ready.pop } }
      organization_membership_ids.length.times { start << true }
      Timeout.timeout(10) { threads.each(&:join) }
      Timeout.timeout(5) do
        organization_membership_ids.length.times.map { results.pop }
      end
    ensure
      threads&.each do |thread|
        next if thread.join(1)

        thread.kill
        thread.join
      end
    end

    def remove_test_records
      ProductMembershipRole.where(
        product_membership_id: ProductMembership.where(
          organization_id: @organization&.id,
          product_id: @product&.id
        ).select(:id)
      ).delete_all
      ProductMembership.where(
        organization_id: @organization&.id,
        product_id: @product&.id
      ).delete_all
      PlanFeatureEntitlement.where(id: @seat_limit_entitlement&.id).delete_all
      PlanProduct.where(id: @plan_product&.id).delete_all
      ProductFeature.where(id: @seat_limit_feature&.id).delete_all
      Product.where(id: @product&.id).delete_all
      Plan.where(id: @plan&.id).delete_all if @owns_free_plan

      return unless @organization

      Organization.transaction do
        OrganizationMembership.where(organization_id: @organization.id).delete_all
        Organization.where(id: @organization.id).delete_all
      end
      Session.where(id: @owner_session&.id).delete_all
      User.where(id: [ @owner&.id, @member&.id ].compact).delete_all
    end
end
