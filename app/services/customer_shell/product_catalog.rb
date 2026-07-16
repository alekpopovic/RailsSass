module CustomerShell
  class ProductCatalog
    ANALYTICS_KEY = Products::Analytics::ActionRegistry::PRODUCT_KEY
    ENTITLEMENT_DENIALS = (
      Access::Gate::PRODUCT_ENTITLEMENT_DENIALS + Access::Gate::FEATURE_ENTITLEMENT_DENIALS
    ).freeze

    Card = Data.define(
      :product,
      :state,
      :message,
      :required_plan,
      :entitlement,
      :access_decision
    ) do
      def available?
        state == :available
      end

      def enabled?
        state.in?(%i[available enabled])
      end

      def locked?
        state == :locked
      end
    end

    def initialize(context:, organization: Current.organization)
      unless organization&.persisted? && Current.organization&.id == organization.id
        raise ActiveRecord::RecordNotFound
      end

      @context = context
      @organization = organization
      @resolver = Entitlements::Resolver.new(organization: organization)
    end

    def call
      Product.where(active: true).order(:name, :id).map { |product| card_for(product) }
    end

    private
      attr_reader :context, :organization, :resolver

      def card_for(product)
        entitlement = resolver.explain(product_key: product.key)
        return generic_card(product, entitlement) unless product.key == ANALYTICS_KEY

        analytics_card(product, entitlement)
      end

      def generic_card(product, entitlement)
        if entitlement.allowed?
          build_card(
            product: product,
            state: :enabled,
            message: "Enabled for your organization. A customer workspace is not available yet.",
            entitlement: entitlement
          )
        else
          locked_card(product, entitlement: entitlement, reason_code: entitlement.reason_code)
        end
      end

      def analytics_card(product, entitlement)
        registry_decision = Products::Analytics::ActionRegistry.decision(
          :dashboard_read,
          context: context
        )
        access_decision = registry_decision.access_decision

        if registry_decision.allowed?
          build_card(
            product: product,
            state: :available,
            message: "Your plan and product role include Analytics dashboard access.",
            entitlement: entitlement,
            access_decision: access_decision
          )
        elsif ENTITLEMENT_DENIALS.include?(registry_decision.reason_code)
          locked_card(
            product,
            entitlement: entitlement,
            reason_code: registry_decision.reason_code,
            access_decision: access_decision,
            feature_key: "dashboards"
          )
        else
          build_card(
            product: product,
            state: access_state(registry_decision.reason_code),
            message: access_message(registry_decision.reason_code),
            entitlement: entitlement,
            access_decision: access_decision
          )
        end
      end

      def locked_card(
        product,
        entitlement:,
        reason_code:,
        access_decision: nil,
        feature_key: nil
      )
        feature_key ||= feature_key_for(reason_code, access_decision)
        required_plan = required_plan_for(product, feature_key: feature_key)
        message = if required_plan
          "The #{required_plan.name} plan is required to unlock this product."
        else
          "No active plan currently unlocks this product."
        end

        build_card(
          product: product,
          state: :locked,
          message: message,
          required_plan: required_plan,
          entitlement: entitlement,
          access_decision: access_decision
        )
      end

      def feature_key_for(reason_code, access_decision)
        return unless Access::Gate::FEATURE_ENTITLEMENT_DENIALS.include?(reason_code)

        access_decision&.feature_key
      end

      def required_plan_for(product, feature_key: nil)
        scope = Plan.where(active: true)
          .joins(:plan_products)
          .where(plan_products: { product_id: product.id })

        if feature_key
          feature_ids = product.product_features.where(active: true, key: feature_key).select(:id)
          scope = scope
            .joins(plan_products: :plan_feature_entitlements)
            .where(plan_feature_entitlements: {
              product_feature_id: feature_ids,
              enabled: true
            })
        end

        scope.distinct.order(:position, :id).first
      end

      def access_message(reason_code)
        case reason_code
        when :permission_not_granted
          "Your product role is missing Analytics dashboard permission."
        when :product_membership_missing
          "Your organization has Analytics, but you need a product assignment."
        when :product_membership_suspended
          "Your Analytics product assignment is suspended."
        when :organization_role_not_product_eligible
          "The billing role can manage billing but cannot access product data."
        else
          "You do not currently have Analytics dashboard access."
        end
      end

      def access_state(reason_code)
        case reason_code
        when :permission_not_granted
          :permission_missing
        when :product_membership_missing, :product_membership_suspended
          :assignment_required
        else
          :unavailable
        end
      end

      def build_card(
        product:,
        state:,
        message:,
        required_plan: nil,
        entitlement:,
        access_decision: nil
      )
        Card.new(
          product: product,
          state: state,
          message: message,
          required_plan: required_plan,
          entitlement: entitlement,
          access_decision: access_decision
        )
      end
  end
end
