class Access::SeedSystemProductRbac
  ADVISORY_LOCK_ID = 20_260_716_020_000

  CATALOG = {
    "analytics" => {
      permissions: [
        {
          key: "analytics.dashboard.read",
          name: "View Analytics dashboard",
          description: "View the Analytics product dashboard."
        },
        {
          key: "analytics.report.read",
          name: "View Analytics reports",
          description: "View custom Analytics reports."
        },
        {
          key: "analytics.report.create",
          name: "Create Analytics reports",
          description: "Create custom Analytics reports."
        },
        {
          key: "analytics.report.manage",
          name: "Manage Analytics reports",
          description: "Manage custom Analytics reports."
        },
        {
          key: "analytics.export.run",
          name: "Export Analytics reports",
          description: "Export Analytics reports as CSV files."
        }
      ],
      role_permissions: {
        "viewer" => %w[
          analytics.dashboard.read
          analytics.report.read
        ],
        "contributor" => %w[
          analytics.dashboard.read
          analytics.report.read
          analytics.report.create
          analytics.export.run
        ],
        "product_admin" => %w[
          analytics.dashboard.read
          analytics.report.read
          analytics.report.create
          analytics.report.manage
          analytics.export.run
        ]
      }
    },
    "crm" => {
      permissions: [
        {
          key: "contacts.view",
          name: "View contacts",
          description: "View CRM contacts."
        },
        {
          key: "contacts.manage",
          name: "Manage contacts",
          description: "Create and manage CRM contacts."
        },
        {
          key: "settings.manage",
          name: "Manage settings",
          description: "Manage CRM product settings."
        }
      ],
      role_permissions: {
        "viewer" => %w[contacts.view],
        "contributor" => %w[contacts.view contacts.manage],
        "product_admin" => %w[contacts.view contacts.manage settings.manage]
      }
    }
  }.freeze

  ROLES = {
    "viewer" => "Viewer",
    "contributor" => "Contributor",
    "product_admin" => "Product Admin"
  }.freeze

  def call
    return false unless local_environment?

    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_ID})"
      )

      catalog.each do |product_key, definition|
        seed_product(product_key, definition)
      end
    end

    true
  end

  private
    def local_environment?
      Rails.env.local?
    end

    def catalog
      CATALOG
    end

    def seed_product(product_key, definition)
      product = Product.find_by!(key: product_key)
      permissions = seed_permissions(product, definition.fetch(:permissions))
      roles = seed_roles(product)

      sync_role_permissions!(
        roles: roles,
        permissions: permissions,
        definitions: definition.fetch(:role_permissions)
      )
    end

    def sync_role_permissions!(roles:, permissions:, definitions:)
      definitions.each do |role_key, permission_keys|
        role = roles.fetch(role_key)
        permission_ids = permission_keys.map { |key| permissions.fetch(key).id }
        role.product_role_permissions.where.not(product_permission_id: permission_ids).delete_all

        permission_keys.each do |permission_key|
          ProductRolePermission.find_or_create_by!(
            product: role.product,
            product_role: role,
            product_permission: permissions.fetch(permission_key)
          )
        end
      end
    end

    def seed_permissions(product, definitions)
      definitions.index_by { |definition| definition.fetch(:key) }.transform_values do |definition|
        permission = ProductPermission.find_or_initialize_by(
          product: product,
          key: definition.fetch(:key)
        )
        permission.assign_attributes(definition.except(:key))
        permission.save!
        permission
      end
    end

    def seed_roles(product)
      ROLES.each_with_object({}) do |(key, name), roles|
        role = ProductRole.find_or_initialize_by(
          product: product,
          organization: nil,
          key: key,
          system: true
        )
        role.assign_attributes(name: name, active: true)
        role.save!
        roles[key] = role
      end
    end
end
