module Access
  class Gate
    AUTHENTICATION_MESSAGE = "Please sign in to continue."
    ORGANIZATION_MESSAGE = "This organization is not available."
    ORGANIZATION_ACCESS_MESSAGE = "You do not have access to this organization."
    PRODUCT_ACCESS_MESSAGE = "You do not have access to this product."
    PRODUCT_PLAN_MESSAGE = "This product is not available on the current plan."
    FEATURE_PLAN_MESSAGE = "This feature is not available on the current plan."

    PRODUCT_ENTITLEMENT_DENIALS = %i[
      catalog_snapshot_invalid
      no_effective_plan
      product_not_found
      product_not_in_plan
    ].freeze
    FEATURE_ENTITLEMENT_DENIALS = %i[
      feature_disabled
      feature_kind_mismatch
      feature_not_entitled
      feature_not_found
      invalid_limit_configuration
    ].freeze

    def initialize(
      context:,
      product_key:,
      permission_key:,
      feature_key: nil,
      now: Time.current
    )
      @context = context
      @product_key = product_key.to_s
      @permission_key = permission_key.to_s
      @feature_key = feature_key&.to_s
      @now = now
    end

    def call
      return decision(:authentication_required) unless authenticated_user?
      return decision(:organization_context_invalid) unless organization_context_valid?
      return decision(:organization_inactive) unless organization_active?

      authoritative_membership = active_organization_membership
      return decision(:organization_membership_inactive) unless authoritative_membership

      entitlement = entitlement_result
      return decision(entitlement.reason_code, entitlement: entitlement) if entitlement.denied?

      permission = PermissionChecker.new(
        organization: Current.organization,
        membership: authoritative_membership,
        product_key: product_key,
        permission_key: permission_key
      ).call
      if permission.product_membership_missing?
        return decision(:product_membership_missing, entitlement: entitlement)
      end
      if permission.product_membership_suspended?
        return decision(:product_membership_suspended, entitlement: entitlement)
      end
      if authoritative_membership.billing?
        return decision(:organization_role_not_product_eligible, entitlement: entitlement)
      end
      unless permission.allowed?
        return decision(:permission_not_granted, entitlement: entitlement)
      end

      decision(:access_granted, entitlement: entitlement)
    end

    private
      attr_reader :context, :product_key, :permission_key, :feature_key, :now

      def authenticated_user?
        context.respond_to?(:authenticated?) && context.authenticated?(now: now)
      end

      def organization_context_valid?
        organization = context_organization
        current_organization = Current.organization

        organization&.persisted? &&
          current_organization&.persisted? &&
          organization.id == current_organization.id
      end

      def organization_active?
        context_organization.active? &&
          Organization.where(id: Current.organization.id, status: "active").exists?
      end

      def active_organization_membership
        membership = context_membership
        return unless membership&.persisted?
        return unless Current.membership&.id == membership.id
        return unless membership.organization_id == Current.organization.id
        return unless membership.user_id == context_user.id

        Current.organization.organization_memberships.active.find_by(
          id: membership.id,
          user_id: context_user.id
        )
      end

      def context_user
        context.user if context.respond_to?(:user)
      end

      def context_organization
        context.organization if context.respond_to?(:organization)
      end

      def context_membership
        context.membership if context.respond_to?(:membership)
      end

      def entitlement_result
        Entitlements::Resolver.new(
          organization: Current.organization,
          now: now
        ).explain(
          product_key: product_key,
          feature_key: feature_key
        )
      end

      def decision(reason_code, entitlement: nil)
        Decision.new(
          allowed: reason_code == :access_granted,
          reason_code: reason_code,
          message: message_for(reason_code),
          plan_key: entitlement&.plan_key,
          plan_source: entitlement&.plan_source,
          product_key: entitlement&.product_key || product_key,
          feature_key: entitlement&.feature_key || feature_key,
          feature_kind: entitlement&.feature_kind,
          limit_value: entitlement&.limit_value,
          unlimited: entitlement&.unlimited? || false,
          details: decision_details(entitlement)
        )
      end

      def decision_details(entitlement)
        return {} unless entitlement

        entitlement.details.merge(entitlement_reason_code: entitlement.reason_code)
      end

      def message_for(reason_code)
        case reason_code
        when :authentication_required
          AUTHENTICATION_MESSAGE
        when :organization_context_invalid, :organization_inactive
          ORGANIZATION_MESSAGE
        when :organization_membership_inactive
          ORGANIZATION_ACCESS_MESSAGE
        when :organization_role_not_product_eligible,
          :product_membership_missing,
          :product_membership_suspended,
          :permission_not_granted
          PRODUCT_ACCESS_MESSAGE
        when *PRODUCT_ENTITLEMENT_DENIALS
          PRODUCT_PLAN_MESSAGE
        when *FEATURE_ENTITLEMENT_DENIALS
          FEATURE_PLAN_MESSAGE
        end
      end
  end
end
