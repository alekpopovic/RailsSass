module Platform
  class ConfigureProviderPriceMapping
    def initialize(actor:, plan_price:, environment:, active: true)
      @actor = actor
      @submitted_plan_price = plan_price
      @environment = environment.to_s
      @active = ActiveModel::Type::Boolean.new.cast(active)
    end

    def call
      ApplicationRecord.transaction do
        actor = lock_authorized_actor!
        plan_price = PlanPrice.lock.find(@submitted_plan_price.id)
        plan_price.plan.lock!
        mapping = plan_price.billing_provider_price_mappings
          .where(provider: "lemon_squeezy", environment: @environment)
          .lock
          .first

        if mapping
          update_mapping!(mapping, actor: actor, plan_price: plan_price)
        else
          create_mapping!(plan_price, actor: actor)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      invalid = @submitted_plan_price.billing_provider_price_mappings.build(
        provider: "lemon_squeezy",
        environment: @environment,
        active: @active
      )
      invalid.errors.add(:base, "conflicts with an existing provider mapping")
      raise ActiveRecord::RecordInvalid, invalid
    end

    private
      def lock_authorized_actor!
        actor = User.lock.find_by(id: @actor&.id)
        return actor if actor&.platform_admin? && actor.authentication_allowed?

        raise Pundit::NotAuthorizedError, "provider price mapping is not allowed"
      end

      def create_mapping!(plan_price, actor:)
        candidate = plan_price.billing_provider_price_mappings.new(
          provider: "lemon_squeezy",
          environment: @environment,
          provider_store_id: plan_price.lemon_store_id,
          provider_product_id: plan_price.lemon_product_id,
          provider_variant_id: plan_price.lemon_variant_id,
          active: @active
        )
        unless plan_price.active? && plan_price.plan.active? && !plan_price.plan.free?
          candidate.errors.add(:base, "requires an active paid plan and active price")
          raise ActiveRecord::RecordInvalid, candidate
        end

        candidate.save!
        record_audit!(
          actor: actor,
          plan_price: plan_price,
          mapping: candidate,
          action: "catalog.created",
          changes: { "environment" => { "from" => nil, "to" => candidate.environment },
                     "active" => { "from" => nil, "to" => candidate.active? } }
        )
        candidate
      end

      def update_mapping!(mapping, actor:, plan_price:)
        was_active = mapping.active?
        mapping.update!(active: @active)
        return mapping if was_active == mapping.active?

        record_audit!(
          actor: actor,
          plan_price: plan_price,
          mapping: mapping,
          action: was_active ? "catalog.deactivated" : "catalog.updated",
          changes: { "active" => { "from" => was_active, "to" => mapping.active? } }
        )
        mapping
      end

      def record_audit!(actor:, plan_price:, mapping:, action:, changes:)
        AuditEvent.create!(
          actor_user: actor,
          action: action,
          subject_type: "PlanPrice",
          subject_id: plan_price.id,
          subject_key: "#{plan_price.plan.key}/price/#{plan_price.id}/#{mapping.environment}",
          change_set: changes,
          occurred_at: Time.current
        )
      end
  end
end
