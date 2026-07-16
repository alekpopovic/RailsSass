require "test_helper"
require "timeout"
require_relative "support"
require_relative "../../../support/audit_event_test_helper"

class Access::ProductMemberships::ConcurrencyTest < ActiveSupport::TestCase
  include AccessProductMembershipsTestSupport
  include AuditEventTestHelper

  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @owner = create_test_user(email_address: "rbac-concurrency-owner-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "RBAC Concurrency #{suffix}",
      slug: "rbac-concurrency-#{suffix}"
    )
    @member = create_test_user(email_address: "rbac-concurrency-member-#{suffix}@example.test")
    @organization_membership = create_test_membership(
      organization: @organization,
      user: @member,
      role: :member
    )
    @product = create_access_test_product(key: "rbac_concurrency_#{suffix}")
    @role = create_access_test_role(product: @product)
    @owner_session, = Session.issue_for!(
      @owner,
      ip_address: nil,
      user_agent: "Product RBAC concurrency test"
    )
    Current.organization = @organization
  end

  teardown do
    Current.reset
    clear_test_audit_events!
    Session.where(id: @owner_session&.id).delete_all

    if @organization
      Organization.transaction do
        ProductMembershipRole.where(organization_id: @organization.id).delete_all
        ProductMembership.where(organization_id: @organization.id).delete_all
        ProductRole.where(organization_id: @organization.id).delete_all
        OrganizationMembership.where(organization_id: @organization.id).delete_all
        @organization.delete
      end
    end
    ProductRole.where(id: @role&.id).delete_all
    Product.where(id: @product&.id).delete_all
    User.where(id: [ @owner&.id, @member&.id ].compact).delete_all
  ensure
    Current.reset
  end

  test "concurrent adds converge to one active product membership" do
    outcomes = run_concurrently(2) do
      Access::ProductMemberships::Add.new(
        organization_membership_id: @organization_membership.id,
        product_id: @product.id
      ).call
    end

    assert outcomes.all?(ProductMembership)
    assert_equal 1, outcomes.map(&:id).uniq.length
    assert_equal 1, @organization.product_memberships.where(
      organization_membership_id: @organization_membership.id,
      product_id: @product.id
    ).count
  end

  test "concurrent role assignments converge to one join" do
    product_membership = Access::ProductMemberships::Add.new(
      organization_membership_id: @organization_membership.id,
      product_id: @product.id
    ).call

    outcomes = run_concurrently(2) do
      Access::ProductMemberships::AssignRole.new(
        product_membership_id: product_membership.id,
        product_role_id: @role.id
      ).call
    end

    assert outcomes.all?(ProductMembershipRole)
    assert_equal 1, outcomes.map(&:id).uniq.length
    assert_equal 1, product_membership.product_membership_roles.where(
      product_role_id: @role.id
    ).count
  end

  test "concurrent add and organization suspension cannot retain an assignment" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    add_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Current.organization = Organization.find(@organization.id)
        ready << true
        start.pop
        results << Access::ProductMemberships::Add.new(
          organization_membership_id: @organization_membership.id,
          product_id: @product.id
        ).call
      rescue => error
        results << error
      ensure
        Current.reset
      end
    end
    remove_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Current.session = Session.includes(:user).find(@owner_session.id)
        Current.organization = Organization.find(@organization.id)
        Current.membership = Current.organization.organization_memberships.find(@owner_membership.id)
        ready << true
        start.pop
        results << Organizations::Memberships::Remove.new(
          actor: Current.user,
          membership_id: @organization_membership.id
        ).call
      rescue => error
        results << error
      ensure
        Current.reset
      end
    end
    threads = [ add_thread, remove_thread ]

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(10) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal 1, outcomes.count { |outcome|
      outcome.is_a?(OrganizationMembership) && outcome.suspended?
    }
    add_outcome = outcomes.find { |outcome| !outcome.is_a?(OrganizationMembership) }
    assert add_outcome.is_a?(ProductMembership) || add_outcome.is_a?(ActiveRecord::RecordInvalid)
    assert_predicate @organization_membership.reload, :suspended?
    assert_empty @organization.product_memberships.where(
      organization_membership_id: @organization_membership.id
    )
  ensure
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  private
    def run_concurrently(count)
      ready = Queue.new
      start = Queue.new
      results = Queue.new
      threads = count.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Current.organization = Organization.find(@organization.id)
            ready << true
            start.pop
            results << yield
          rescue => error
            results << error
          ensure
            Current.reset
          end
        end
      end

      Timeout.timeout(5) { count.times { ready.pop } }
      count.times { start << true }
      Timeout.timeout(10) { threads.each(&:join) }
      Timeout.timeout(5) { count.times.map { results.pop } }
    ensure
      threads&.each do |thread|
        next if thread.join(1)

        thread.kill
        thread.join
      end
    end
end
