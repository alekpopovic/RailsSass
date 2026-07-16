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
      Current.organization = @organization
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
      product: @product
    )
      Access::ProductMemberships::Add.new(
        organization_membership_id: organization_membership.id,
        product_id: product.id
      ).call
    end

    def assign_product_role(product_membership:, product_role:)
      Access::ProductMemberships::AssignRole.new(
        product_membership_id: product_membership.id,
        product_role_id: product_role.id
      ).call
    end
end
