require "test_helper"

class Access::SeedSystemProductRbacTest < ActiveSupport::TestCase
  PRODUCT_KEYS = %w[analytics crm].freeze
  ROLE_KEYS = %w[contributor product_admin viewer].freeze

  setup do
    Catalog::SeedLocalCatalog.new.call
  end

  test "the database seed loads the exact local system roles permissions and mappings" do
    Rails.application.load_seed

    assert_equal expected_roles, seeded_role_rows
    assert_equal expected_permissions, seeded_permission_rows
    assert_equal expected_mappings, seeded_mapping_rows
    assert_empty ProductRole.joins(:product).where(products: { key: "core" })
    assert_empty ProductPermission.joins(:product).where(products: { key: "core" })
  end

  test "repeated seeds repair mutable metadata without changing stable identities" do
    service = Access::SeedSystemProductRbac.new
    service.call
    role_ids = seeded_roles.index_by { |role| [ role.product_id, role.key ] }.transform_values(&:id)
    permission_ids = seeded_permissions
      .index_by { |permission| [ permission.product_id, permission.key ] }
      .transform_values(&:id)
    mapping_ids = seeded_role_permissions
      .index_by { |mapping| [ mapping.product_role_id, mapping.product_permission_id ] }
      .transform_values(&:id)

    analytics = Product.find_by!(key: "analytics")
    ProductRole.find_by!(product: analytics, organization: nil, key: "viewer")
      .update!(name: "Renamed Viewer", active: false)
    ProductPermission.find_by!(product: analytics, key: "analytics.report.read")
      .update!(name: "Renamed permission", description: "Changed description.")

    2.times { assert service.call }

    assert_equal role_ids,
      seeded_roles.index_by { |role| [ role.product_id, role.key ] }.transform_values(&:id)
    assert_equal permission_ids,
      seeded_permissions
        .index_by { |permission| [ permission.product_id, permission.key ] }
        .transform_values(&:id)
    assert_equal mapping_ids,
      seeded_role_permissions
        .index_by { |mapping| [ mapping.product_role_id, mapping.product_permission_id ] }
        .transform_values(&:id)
    assert_equal expected_roles, seeded_role_rows
    assert_equal expected_permissions, seeded_permission_rows
    assert_equal expected_mappings, seeded_mapping_rows
  end

  test "a missing reviewed role permission mapping is restored" do
    service = Access::SeedSystemProductRbac.new
    service.call
    analytics = Product.find_by!(key: "analytics")
    viewer = ProductRole.find_by!(product: analytics, organization: nil, key: "viewer")
    view_reports = ProductPermission.find_by!(product: analytics, key: "analytics.report.read")
    ProductRolePermission.find_by!(
      product_role: viewer,
      product_permission: view_reports
    ).destroy!

    assert_difference("ProductRolePermission.count", 1) { assert service.call }
    assert_equal expected_mappings, seeded_mapping_rows
  end

  test "legacy mappings on seeded roles are removed without deleting stable permission identities" do
    service = Access::SeedSystemProductRbac.new
    service.call
    analytics = Product.find_by!(key: "analytics")
    viewer = ProductRole.find_by!(product: analytics, organization: nil, key: "viewer")
    obsolete_permission = ProductPermission.find_or_create_by!(
      product: analytics,
      key: "reports.view"
    ) do |permission|
      permission.name = "Legacy report viewer"
      permission.description = "Synthetic legacy Analytics permission."
    end
    obsolete_mapping = ProductRolePermission.create!(
      product: analytics,
      product_role: viewer,
      product_permission: obsolete_permission
    )

    assert_no_difference("ProductPermission.count") { assert service.call }

    assert_not ProductRolePermission.exists?(obsolete_mapping.id)
    assert ProductPermission.exists?(obsolete_permission.id)
    assert_equal expected_mappings, seeded_mapping_rows
  end

  test "the local RBAC seed is a no-op outside development and test" do
    remove_seed_records
    non_local_seed = Class.new(Access::SeedSystemProductRbac) do
      private
        def local_environment?
          false
        end
    end

    assert_not non_local_seed.new.call
    assert_empty seeded_roles
    assert_empty seeded_permissions
    assert_empty seeded_role_permissions
  end

  test "a failed seed rolls back all products in its catalog" do
    remove_seed_records
    failing_seed = Class.new(Access::SeedSystemProductRbac) do
      private
        def seed_product(product_key, definition)
          super
          raise "synthetic seed failure" if product_key == "crm"
        end
    end

    error = assert_raises(RuntimeError) { failing_seed.new.call }

    assert_equal "synthetic seed failure", error.message
    assert_empty seeded_roles
    assert_empty seeded_permissions
    assert_empty seeded_role_permissions
  end

  private
    def products
      Product.where(key: PRODUCT_KEYS)
    end

    def seeded_roles
      ProductRole.where(product: products, organization: nil, key: ROLE_KEYS)
    end

    def seeded_permissions
      ProductPermission.where(product: products).where(
        key: %w[
          analytics.dashboard.read
          analytics.export.run
          analytics.report.create
          analytics.report.manage
          analytics.report.read
          contacts.manage
          contacts.view
          settings.manage
        ]
      )
    end

    def seeded_role_permissions
      ProductRolePermission.where(product_role: seeded_roles)
    end

    def seeded_role_rows
      ProductRole.joins(:product)
        .where(products: { key: PRODUCT_KEYS }, organization_id: nil, key: ROLE_KEYS)
        .order("products.key", "product_roles.key")
        .pluck("products.key", "product_roles.key", "product_roles.name", :system, :active)
    end

    def seeded_permission_rows
      ProductPermission.joins(:product)
        .where(
          products: { key: PRODUCT_KEYS },
          product_permissions: {
            key: %w[
              analytics.dashboard.read
              analytics.export.run
              analytics.report.create
              analytics.report.manage
              analytics.report.read
              contacts.manage
              contacts.view
              settings.manage
            ]
          }
        )
        .order("products.key", "product_permissions.key")
        .pluck(
          "products.key",
          "product_permissions.key",
          "product_permissions.name",
          "product_permissions.description"
        )
    end

    def seeded_mapping_rows
      ProductRolePermission
        .joins(:product, :product_role, :product_permission)
        .where(products: { key: PRODUCT_KEYS }, product_roles: { organization_id: nil, key: ROLE_KEYS })
        .order("products.key", "product_roles.key", "product_permissions.key")
        .pluck("products.key", "product_roles.key", "product_permissions.key")
    end

    def expected_roles
      [
        [ "analytics", "contributor", "Contributor", true, true ],
        [ "analytics", "product_admin", "Product Admin", true, true ],
        [ "analytics", "viewer", "Viewer", true, true ],
        [ "crm", "contributor", "Contributor", true, true ],
        [ "crm", "product_admin", "Product Admin", true, true ],
        [ "crm", "viewer", "Viewer", true, true ]
      ]
    end

    def expected_permissions
      [
        [
          "analytics",
          "analytics.dashboard.read",
          "View Analytics dashboard",
          "View the Analytics product dashboard."
        ],
        [
          "analytics",
          "analytics.export.run",
          "Export Analytics reports",
          "Export Analytics reports as CSV files."
        ],
        [
          "analytics",
          "analytics.report.create",
          "Create Analytics reports",
          "Create custom Analytics reports."
        ],
        [
          "analytics",
          "analytics.report.manage",
          "Manage Analytics reports",
          "Manage custom Analytics reports."
        ],
        [
          "analytics",
          "analytics.report.read",
          "View Analytics reports",
          "View custom Analytics reports."
        ],
        [ "crm", "contacts.manage", "Manage contacts", "Create and manage CRM contacts." ],
        [ "crm", "contacts.view", "View contacts", "View CRM contacts." ],
        [ "crm", "settings.manage", "Manage settings", "Manage CRM product settings." ]
      ]
    end

    def expected_mappings
      [
        [ "analytics", "contributor", "analytics.dashboard.read" ],
        [ "analytics", "contributor", "analytics.export.run" ],
        [ "analytics", "contributor", "analytics.report.create" ],
        [ "analytics", "contributor", "analytics.report.read" ],
        [ "analytics", "product_admin", "analytics.dashboard.read" ],
        [ "analytics", "product_admin", "analytics.export.run" ],
        [ "analytics", "product_admin", "analytics.report.create" ],
        [ "analytics", "product_admin", "analytics.report.manage" ],
        [ "analytics", "product_admin", "analytics.report.read" ],
        [ "analytics", "viewer", "analytics.dashboard.read" ],
        [ "analytics", "viewer", "analytics.report.read" ],
        [ "crm", "contributor", "contacts.manage" ],
        [ "crm", "contributor", "contacts.view" ],
        [ "crm", "product_admin", "contacts.manage" ],
        [ "crm", "product_admin", "contacts.view" ],
        [ "crm", "product_admin", "settings.manage" ],
        [ "crm", "viewer", "contacts.view" ]
      ]
    end

    def remove_seed_records
      seeded_role_permissions.delete_all
      seeded_roles.delete_all
      seeded_permissions.delete_all
    end
end
