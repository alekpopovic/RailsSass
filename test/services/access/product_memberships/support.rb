require_relative "../../../support/organization_test_helper"

module AccessProductMembershipsTestSupport
  include OrganizationTestHelper

  private
    def create_access_test_records
      suffix = SecureRandom.hex(6)
      @owner = create_test_user(email_address: "product-access-owner-#{suffix}@example.test")
      @organization, @owner_membership = create_test_organization_with_owner(
        owner: @owner,
        name: "Product Access #{suffix}",
        slug: "product-access-#{suffix}"
      )
      @member = create_test_user(email_address: "product-access-member-#{suffix}@example.test")
      @organization_membership = create_test_membership(
        organization: @organization,
        user: @member,
        role: :member
      )
      @product = create_access_test_product(key: "analytics_#{suffix}")
      create_access_test_product_entitlement
      establish_tenant_context(
        user: @owner,
        organization: @organization,
        membership: @owner_membership
      )
    end

    def create_access_test_product(key:, active: true)
      Product.create!(
        key: key,
        name: key.humanize,
        description: "Product membership service test product.",
        active: active
      )
    end

    def create_access_test_role(
      product: @product,
      organization: nil,
      key: "viewer",
      active: true
    )
      ProductRole.create!(
        product: product,
        organization: organization,
        key: key,
        name: key.humanize,
        system: organization.nil?,
        active: active
      )
    end

    def add_product_membership(
      organization_membership: @organization_membership,
      product: @product,
      actor: @owner
    )
      Access::ProductMemberships::Add.new(
        organization_membership_id: organization_membership.id,
        product_id: product.id,
        actor: actor
      ).call
    end

    def assign_product_role(product_membership:, product_role:, actor: @owner)
      Access::ProductMemberships::AssignRole.new(
        product_membership_id: product_membership.id,
        product_role_id: product_role.id,
        actor: actor
      ).call
    end

    def create_access_test_product_entitlement
      @plan = Plan.find_by(active: true, free: true)
      @owns_access_test_plan = @plan.nil?
      @plan ||= Plan.create!(
        key: "product_access_free_#{SecureRandom.hex(6)}",
        name: "Product Access Free",
        description: "Free plan for product membership service tests.",
        active: true,
        free: true,
        position: 0
      )
      @plan_product = PlanProduct.create!(plan: @plan, product: @product)
    end
end
