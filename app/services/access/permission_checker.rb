class Access::PermissionChecker
  Result = Data.define(:product_membership_status, :permission_granted) do
    VALID_PRODUCT_MEMBERSHIP_STATUSES = [ nil, "active", "suspended" ].freeze

    def initialize(product_membership_status:, permission_granted:)
      unless VALID_PRODUCT_MEMBERSHIP_STATUSES.include?(product_membership_status)
        raise ArgumentError, "invalid product membership status"
      end
      unless [ true, false ].include?(permission_granted)
        raise ArgumentError, "permission_granted must be a boolean"
      end

      super
    end

    def product_membership_missing?
      product_membership_status.nil?
    end

    def product_membership_suspended?
      product_membership_status == "suspended"
    end

    def permission_granted?
      permission_granted
    end

    def allowed?
      product_membership_status == "active" && permission_granted?
    end
  end

  def initialize(organization:, membership:, product_key:, permission_key:)
    @organization = organization
    @membership = membership
    @product_key = product_key.to_s
    @permission_key = permission_key.to_s
  end

  def call
    return denied unless valid_context?

    product_membership = find_product_membership
    return denied unless product_membership
    return denied(product_membership.status) unless product_membership.active?

    Result.new(
      product_membership_status: product_membership.status,
      permission_granted: permission_granted?(product_membership)
    )
  end

  private
    attr_reader :organization, :membership, :product_key, :permission_key

    def valid_context?
      current_organization = Current.organization

      current_organization&.persisted? &&
        current_organization.active? &&
        organization&.persisted? &&
        organization.id == current_organization.id &&
        membership&.persisted? &&
        membership.active? &&
        membership.organization_id == current_organization.id
    end

    def find_product_membership
      Current.organization.product_memberships
        .joins(:product)
        .select(
          :id,
          :organization_id,
          :organization_membership_id,
          :product_id,
          :status
        )
        .find_by(
          organization_membership_id: membership.id,
          products: { key: product_key }
        )
    end

    def permission_granted?(product_membership)
      Current.organization.product_memberships
        .where(
          id: product_membership.id,
          organization_membership_id: membership.id,
          product_id: product_membership.product_id,
          status: "active"
        )
        .joins(
          product_membership_roles: {
            product_role: { product_role_permissions: :product_permission }
          }
        )
        .where(product_membership_roles: {
          organization_id: Current.organization.id,
          product_id: product_membership.product_id
        })
        .where(product_roles: {
          product_id: product_membership.product_id,
          active: true
        })
        .where(product_role_permissions: { product_id: product_membership.product_id })
        .where(product_permissions: {
          product_id: product_membership.product_id,
          key: permission_key
        })
        .where(
          <<~SQL.squish,
            (
              product_roles.organization_id IS NULL
              AND product_roles.system = TRUE
            ) OR (
              product_roles.organization_id = :organization_id
              AND product_roles.system = FALSE
            )
          SQL
          organization_id: Current.organization.id
        )
        .exists?
    end

    def denied(product_membership_status = nil)
      Result.new(
        product_membership_status: product_membership_status,
        permission_granted: false
      )
    end
end
