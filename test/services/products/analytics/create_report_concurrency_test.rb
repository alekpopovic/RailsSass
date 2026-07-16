require "test_helper"
require "timeout"
require_relative "../../../support/analytics_test_helper"

class Products::Analytics::CreateReportConcurrencyTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  self.use_transactional_tests = false

  setup do
    @preexisting_product_id = Product.find_by(
      key: Products::Analytics::ActionRegistry::PRODUCT_KEY
    )&.id
    @preexisting_feature_ids = ProductFeature.joins(:product).where(
      products: { key: Products::Analytics::ActionRegistry::PRODUCT_KEY },
      product_features: { key: %w[custom_reports report_limit] }
    ).pluck(:id)
    @preexisting_permission_ids = ProductPermission.joins(:product).where(
      products: { key: Products::Analytics::ActionRegistry::PRODUCT_KEY },
      product_permissions: { key: "analytics.report.create" }
    ).pluck(:id)
    @preexisting_free_plan_id = Plan.find_by(active: true, free: true)&.id
    existing_product = Product.find_by(key: Products::Analytics::ActionRegistry::PRODUCT_KEY)
    @preexisting_plan_product_id = if @preexisting_free_plan_id && existing_product
      PlanProduct.find_by(
        plan_id: @preexisting_free_plan_id,
        product_id: existing_product.id
      )&.id
    end
    @preexisting_entitlements = if @preexisting_plan_product_id
      PlanFeatureEntitlement.where(plan_product_id: @preexisting_plan_product_id)
        .index_by(&:id)
        .transform_values { |entitlement| entitlement.attributes.except("created_at", "updated_at") }
    else
      {}
    end
    @analytics = create_analytics_context(limit_value: 1, use_paid_plan: false)
    Current.reset
  end

  teardown do
    Current.reset
    remove_analytics_context
  ensure
    Current.reset
  end

  test "two concurrent creates can consume the final report slot only once" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          establish_thread_context
          ready << true
          start.pop
          results << Products::Analytics::CreateReport.new(
            context: AuthorizationContext.current,
            attributes: {
              name: "Concurrent report #{index}",
              description: "Synthetic concurrent report."
            }
          ).call
        rescue => error
          results << error
        ensure
          Current.reset
        end
      end
    end

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(10) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(AnalyticsReport) }
    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(ActiveRecord::RecordInvalid) }
    assert_equal 1, AnalyticsReport.where(organization_id: @analytics.organization.id).count
    error = outcomes.grep(ActiveRecord::RecordInvalid).sole
    assert_equal [ Products::Analytics::CreateReport::LIMIT_REACHED_MESSAGE ],
      error.record.errors[:base]
  ensure
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  private
    def establish_thread_context
      Current.session = Session.includes(:user).find(@analytics.session.id)
      Current.organization = Organization.find(@analytics.organization.id)
      Current.membership = Current.organization.organization_memberships.find(
        @analytics.organization_membership.id
      )
    end

    def remove_analytics_context
      return unless @analytics

      ApplicationRecord.transaction do
        AnalyticsReport.where(organization_id: @analytics.organization.id).delete_all
        ProductMembershipRole.where(organization_id: @analytics.organization.id).delete_all
        ProductMembership.where(organization_id: @analytics.organization.id).delete_all
        OrganizationAccessLocator.where(organization_id: @analytics.organization.id).delete_all
        OrganizationMembership.where(organization_id: @analytics.organization.id).delete_all
        Organization.where(id: @analytics.organization.id).delete_all
      end

      Session.where(user_id: @analytics.user.id).delete_all
      User.where(id: @analytics.user.id).delete_all
      ProductRolePermission.where(product_role_id: @analytics.role.id).delete_all
      ProductRole.where(id: @analytics.role.id).delete_all
      restore_plan_entitlements
      PlanProduct.where(id: @analytics.plan_product.id)
        .where.not(id: @preexisting_plan_product_id)
        .delete_all
      Plan.where(id: @analytics.plan.id)
        .where.not(id: @preexisting_free_plan_id)
        .delete_all

      ProductPermission.where(id: @analytics.permission.id)
        .where.not(id: @preexisting_permission_ids)
        .delete_all
      ProductFeature.where(
        id: [ @analytics.custom_reports_feature.id, @analytics.report_limit_feature.id ]
      ).where.not(id: @preexisting_feature_ids).delete_all
      Product.where(id: @analytics.product.id)
        .where.not(id: @preexisting_product_id)
        .delete_all
    end

    def restore_plan_entitlements
      PlanFeatureEntitlement.where(plan_product_id: @analytics.plan_product.id)
        .where.not(id: @preexisting_entitlements.keys)
        .delete_all
      @preexisting_entitlements.each_value do |attributes|
        PlanFeatureEntitlement.find(attributes.fetch("id")).update_columns(
          attributes.except("id", "plan_product_id", "product_feature_id", "product_id", "feature_kind")
        )
      end
    end
end
