module Entitlements
  class Resolver
    CACHE_VERSION = "v1"
    CACHE_TTL = 12.hours

    PlanContext = Data.define(
      :plan,
      :subscription,
      :source,
      :subscription_reason_code,
      :fallback_reason_code
    )

    def initialize(
      organization: Current.organization,
      now: Time.current,
      cache: Rails.cache,
      past_due_grace_period: Rails.application.config.x.entitlements.past_due_grace_period
    )
      current_organization = Current.organization
      unless current_organization&.persisted? && organization&.id == current_organization.id
        raise ActiveRecord::RecordNotFound
      end

      @organization = current_organization
      @now = now
      @cache = cache
      @past_due_grace_period = past_due_grace_period
    end

    def product_enabled?(product_key)
      explain(product_key: product_key).allowed?
    end

    def feature_enabled?(product_key, feature_key)
      return false if feature_key.nil?

      explain(product_key: product_key, feature_key: feature_key).allowed?
    end

    def limit(product_key, feature_key)
      explain(product_key: product_key, feature_key: feature_key).capacity
    end

    def enabled_products
      return [] unless effective_plan

      products = entitlement_products
      return [] unless products

      products.filter_map do |key, product|
        key if key.is_a?(String) && product.is_a?(Hash) && product["granted"] == true
      end.sort
    end

    def explain(product_key:, feature_key: nil)
      context = plan_context
      return no_effective_plan_result(product_key, feature_key) unless context.plan

      normalized_product_key = product_key.to_s
      products = entitlement_products
      return result(false, :catalog_snapshot_invalid, product_key: normalized_product_key) unless products

      product = products[normalized_product_key]
      return result(false, :product_not_found, product_key: normalized_product_key) unless product
      unless product.is_a?(Hash)
        return result(false, :catalog_snapshot_invalid, product_key: normalized_product_key)
      end
      return result(false, :product_not_in_plan, product_key: normalized_product_key) unless
        product["granted"] == true

      return result(true, :product_enabled, product_key: normalized_product_key) if feature_key.nil?

      explain_feature(
        product: product,
        product_key: normalized_product_key,
        feature_key: feature_key.to_s
      )
    end

    def effective_plan
      plan_context.plan
    end

    private
      attr_reader :organization, :now, :cache, :past_due_grace_period

      def explain_feature(product:, product_key:, feature_key:)
        features = product["features"]
        entitlements = product["entitlements"]
        unless features.is_a?(Hash) && entitlements.is_a?(Hash)
          return result(
            false,
            :catalog_snapshot_invalid,
            product_key: product_key,
            feature_key: feature_key
          )
        end

        feature = features[feature_key]
        return result(false, :feature_not_found, product_key: product_key, feature_key: feature_key) unless feature
        unless feature.is_a?(Hash)
          return result(
            false,
            :catalog_snapshot_invalid,
            product_key: product_key,
            feature_key: feature_key
          )
        end

        entitlement = entitlements[feature_key]
        unless entitlement
          return result(
            false,
            :feature_not_entitled,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature["kind"]
          )
        end
        unless entitlement.is_a?(Hash)
          return result(
            false,
            :catalog_snapshot_invalid,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature["kind"]
          )
        end

        unless entitlement["product_matches"] == true &&
            entitlement["feature_kind"] == feature["kind"]
          return result(
            false,
            :feature_kind_mismatch,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature["kind"]
          )
        end

        unless entitlement["enabled"] == true
          return result(
            false,
            :feature_disabled,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature["kind"]
          )
        end

        typed_feature_result(
          entitlement: entitlement,
          product_key: product_key,
          feature_key: feature_key,
          feature_kind: feature["kind"]
        )
      end

      def typed_feature_result(entitlement:, product_key:, feature_key:, feature_kind:)
        case feature_kind
        when "flag"
          return invalid_limit_result(product_key, feature_key, feature_kind) unless
            entitlement["limit_value"].nil? && entitlement["unlimited"] == false

          result(
            true,
            :feature_enabled,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature_kind
          )
        when "limit"
          return invalid_limit_result(product_key, feature_key, feature_kind) unless
            valid_limit_configuration?(entitlement)

          result(
            true,
            :feature_enabled,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature_kind,
            limit_value: entitlement["limit_value"],
            unlimited: entitlement["unlimited"]
          )
        else
          result(
            false,
            :feature_kind_mismatch,
            product_key: product_key,
            feature_key: feature_key,
            feature_kind: feature_kind
          )
        end
      end

      def valid_limit_configuration?(entitlement)
        if entitlement["unlimited"] == true
          entitlement["limit_value"].nil?
        else
          entitlement["unlimited"] == false &&
            entitlement["limit_value"].is_a?(Integer) &&
            entitlement["limit_value"] >= 0
        end
      end

      def invalid_limit_result(product_key, feature_key, feature_kind)
        result(
          false,
          :invalid_limit_configuration,
          product_key: product_key,
          feature_key: feature_key,
          feature_kind: feature_kind
        )
      end

      def no_effective_plan_result(product_key, feature_key)
        result(
          false,
          :no_effective_plan,
          product_key: product_key.to_s,
          feature_key: feature_key&.to_s
        )
      end

      def result(
        allowed,
        reason_code,
        product_key: nil,
        feature_key: nil,
        feature_kind: nil,
        limit_value: nil,
        unlimited: false
      )
        context = plan_context
        Result.new(
          allowed: allowed,
          reason_code: reason_code,
          plan_key: context.plan&.key,
          plan_source: context.source,
          product_key: product_key,
          feature_key: feature_key,
          feature_kind: feature_kind,
          limit_value: limit_value,
          unlimited: unlimited,
          details: {
            subscription_reason_code: context.subscription_reason_code,
            fallback_reason_code: context.fallback_reason_code
          }.compact
        )
      end

      def plan_context
        return @plan_context if defined?(@plan_context)

        subscription = current_subscription
        subscription_result = SubscriptionAccessPolicy.new(
          subscription: subscription,
          now: now,
          past_due_grace_period: past_due_grace_period
        ).call

        paid_plan = subscription&.plan_price&.plan
        if subscription_result.allowed? && paid_plan && !paid_plan.free?
          @plan_context = PlanContext.new(
            plan: paid_plan,
            subscription: subscription,
            source: :paid,
            subscription_reason_code: subscription_result.reason_code,
            fallback_reason_code: nil
          )
          return @plan_context
        end

        subscription_reason_code = if subscription_result.allowed? && paid_plan.nil?
          :subscription_plan_missing
        elsif subscription_result.allowed? && paid_plan&.free?
          :subscription_plan_is_free
        else
          subscription_result.reason_code
        end

        free_plan = Plan.find_by(active: true, free: true)
        @plan_context = PlanContext.new(
          plan: free_plan,
          subscription: subscription,
          source: free_plan ? :free : nil,
          subscription_reason_code: subscription_reason_code,
          fallback_reason_code: free_plan ? nil : :active_free_plan_missing
        )
      end

      def current_subscription
        return @current_subscription if defined?(@current_subscription)

        @current_subscription = organization.billing_subscriptions
          .includes(plan_price: :plan)
          .find_by(current: true)
      end

      def entitlement_snapshot
        return @entitlement_snapshot if defined?(@entitlement_snapshot)

        @entitlement_snapshot = cache.fetch(entitlement_cache_key, expires_in: CACHE_TTL) do
          build_entitlement_snapshot
        end
      end

      def entitlement_products
        snapshot = entitlement_snapshot
        return unless snapshot.is_a?(Hash) && snapshot["products"].is_a?(Hash)

        snapshot["products"]
      end

      def entitlement_cache_key
        [
          "entitlements",
          CACHE_VERSION,
          effective_plan.cache_key_with_version,
          plan_context.subscription&.cache_key_with_version || "no-subscription",
          Product.all.cache_key_with_version,
          ProductFeature.all.cache_key_with_version,
          plan_products_scope.cache_key_with_version,
          plan_entitlements_scope.cache_key_with_version
        ]
      end

      def plan_products_scope
        @plan_products_scope ||= PlanProduct.where(plan_id: effective_plan.id)
      end

      def plan_entitlements_scope
        @plan_entitlements_scope ||= PlanFeatureEntitlement.where(
          plan_product_id: plan_products_scope.select(:id)
        )
      end

      def build_entitlement_snapshot
        products = {}
        products_by_id = {}
        features_by_id = {}

        Product.order(:id).pluck(:id, :key).each do |id, key|
          product = {
            "id" => id,
            "granted" => false,
            "features" => {},
            "entitlements" => {}
          }
          products[key] = product
          products_by_id[id] = product
        end

        ProductFeature.order(:id).pluck(:id, :product_id, :key, :kind).each do |id, product_id, key, kind|
          product = products_by_id[product_id]
          next unless product

          feature = { "id" => id, "product_id" => product_id, "key" => key, "kind" => kind }
          product["features"][key] = feature
          features_by_id[id] = feature
        end

        plan_products_by_id = {}
        plan_products_scope.order(:id).pluck(:id, :product_id).each do |id, product_id|
          product = products_by_id[product_id]
          next unless product

          product["granted"] = true
          plan_products_by_id[id] = product
        end

        plan_entitlements_scope.order(:id).pluck(
          :plan_product_id,
          :product_feature_id,
          :product_id,
          :feature_kind,
          :enabled,
          :limit_value,
          :unlimited
        ).each do |plan_product_id, product_feature_id, product_id, feature_kind, enabled, limit_value, unlimited|
          product = plan_products_by_id[plan_product_id]
          feature = features_by_id[product_feature_id]
          next unless product && feature

          product["entitlements"][feature["key"]] = {
            "enabled" => enabled,
            "feature_kind" => feature_kind,
            "limit_value" => limit_value,
            "unlimited" => unlimited,
            "product_matches" => product["id"] == product_id && feature["product_id"] == product_id
          }
        end

        { "products" => products }
      end
  end
end
