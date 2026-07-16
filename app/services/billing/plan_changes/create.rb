module Billing
  module PlanChanges
    class Create
      DEFINITIVE_CLIENT_STATUSES = [ 400, 401, 403, 404, 409, 422 ].freeze

      Result = Data.define(:plan_change, :compatibility, :duplicate) do
        def duplicate?
          duplicate
        end
      end

      class Error < StandardError
        attr_reader :plan_change

        def initialize(message, plan_change: nil)
          super(message)
          @plan_change = plan_change
        end
      end

      class NoSubscription < Error; end
      class InvalidPrice < Error; end
      class ChangePending < Error; end

      class IncompatiblePlan < Error
        attr_reader :compatibility

        def initialize(message, compatibility:)
          super(message)
          @compatibility = compatibility
        end
      end

      class ProviderFailure < Error
        def initialize(message, plan_change:, ambiguous:)
          super(message, plan_change: plan_change)
          @ambiguous = ambiguous
        end

        def ambiguous?
          @ambiguous
        end
      end

      class ProviderVariantMismatch < Error; end

      def initialize(
        organization:,
        user:,
        plan_price:,
        compatibility_checker:,
        client: nil,
        now: Time.current
      )
        @organization = organization
        @user = user
        @submitted_plan_price = plan_price
        @compatibility_checker = compatibility_checker
        @client = client
        @now = now
      end

      def call
        authorize_context!
        client = @client || Billing::LemonSqueezy::Client.new
        command = create_command!(client)
        return command if command.duplicate?

        plan_change = command.plan_change
        snapshot = client.update_subscription_variant(
          provider_subscription_id: plan_change.billing_subscription.provider_subscription_id,
          variant_id: plan_change.to_plan_price.lemon_variant_id
        )
        validate_provider_response!(plan_change, snapshot)

        Result.new(
          plan_change: mark_submitted!(plan_change, snapshot),
          compatibility: command.compatibility,
          duplicate: false
        )
      rescue ProviderVariantMismatch => error
        transitioned = mark_failed!(error.plan_change, "provider_variant_mismatch")
        return terminal_result(transitioned) if transitioned.status_applied? || transitioned.status_superseded?

        raise ProviderFailure.new(
          "Provider did not confirm the requested variant",
          plan_change: transitioned,
          ambiguous: false
        ), cause: nil
      rescue Billing::LemonSqueezy::Errors::Error => error
        raise unless defined?(plan_change) && plan_change&.persisted?

        transitioned = transition_provider_failure!(plan_change, error)
        return terminal_result(transitioned) if transitioned.status_applied? || transitioned.status_superseded?

        raise ProviderFailure.new(
          "Plan change could not be confirmed safely",
          plan_change: transitioned,
          ambiguous: !definitive_failure?(error)
        ), cause: nil
      rescue ActiveRecord::RecordNotUnique
        recover_duplicate!
      end

      private
        def authorize_context!
          ApplicationRecord.transaction { lock_and_authorize_context! }
        end

        def create_command!(client)
          ApplicationRecord.transaction do
            lock_and_authorize_context!
            subscription = Current.organization.billing_subscriptions
              .includes(plan_price: :plan)
              .where(current: true)
              .lock
              .first
            validate_subscription!(subscription, client)

            existing = Current.organization.billing_plan_changes
              .open
              .where(billing_subscription_id: subscription.id)
              .lock
              .first
            return duplicate_result(existing) if existing&.to_plan_price_id == @submitted_plan_price&.id
            if existing
              raise ChangePending.new("Another plan change is pending", plan_change: existing)
            end

            target_price = PlanPrice.includes(:plan).lock.find_by(id: @submitted_plan_price&.id)
            mapping = target_mapping(target_price, subscription, client, lock: true)
            validate_target!(target_price, mapping, subscription, client)

            compatibility = @compatibility_checker.call(
              organization: Current.organization,
              from_plan: subscription.plan_price.plan,
              to_plan: target_price.plan
            )
            unless compatibility.compatible?
              raise IncompatiblePlan.new(
                "Current product usage exceeds the target plan",
                compatibility: compatibility
              )
            end

            plan_change = Current.organization.billing_plan_changes.create!(
              billing_subscription: subscription,
              requested_by_membership: Current.membership,
              from_plan_price: subscription.plan_price,
              to_plan_price: target_price,
              provider: subscription.provider,
              environment: subscription.environment,
              test_mode: subscription.test_mode,
              status: :pending,
              requested_at: @now
            )

            Result.new(plan_change: plan_change, compatibility: compatibility, duplicate: false)
          end
        end

        def duplicate_result(plan_change)
          Result.new(plan_change: plan_change, compatibility: nil, duplicate: true)
        end

        def recover_duplicate!
          plan_change = Current.organization.billing_plan_changes
            .open
            .order(requested_at: :desc, id: :desc)
            .first
          if plan_change&.to_plan_price_id == @submitted_plan_price&.id
            duplicate_result(plan_change)
          else
            raise ChangePending.new("Another plan change is pending", plan_change: plan_change)
          end
        end

        def validate_subscription!(subscription, client)
          raise NoSubscription, "A current subscription is required" unless subscription

          valid = subscription.current? &&
            subscription.provider == "lemon_squeezy" &&
            subscription.environment == client.environment &&
            subscription.test_mode == client.test_mode? &&
            subscription.sync_state_synced? &&
            !subscription.status_expired? &&
            !subscription.status_unknown?
          raise NoSubscription, "The current subscription cannot be changed" unless valid
        end

        def target_mapping(target_price, subscription, client, lock: false)
          scope = Billing::ProviderPriceMapping.where(
            plan_price_id: target_price&.id,
            provider: subscription.provider,
            environment: subscription.environment,
            provider_store_id: client.store_id,
            active: true
          )
          scope = scope.lock if lock
          scope.first
        end

        def validate_target!(target_price, mapping, subscription, client)
          valid = target_price&.persisted? &&
            target_price.id != subscription.plan_price_id &&
            target_price.active? &&
            target_price.plan.active? &&
            !target_price.plan.free? &&
            target_price.lemon_variant_id.present? &&
            mapping&.checkout_eligible? &&
            mapping.provider == subscription.provider &&
            mapping.environment == client.environment &&
            mapping.provider_store_id == client.store_id &&
            mapping.provider_variant_id == target_price.lemon_variant_id
          raise InvalidPrice, "Plan price is unavailable" unless valid
        end

        def validate_provider_response!(plan_change, snapshot)
          subscription = plan_change.billing_subscription
          mapping = plan_change.to_plan_price.billing_provider_price_mappings.find_by(
            provider: plan_change.provider,
            environment: plan_change.environment
          )
          valid = mapping &&
            snapshot.provider_subscription_id == subscription.provider_subscription_id &&
            snapshot.provider_customer_id == subscription.provider_customer_id &&
            snapshot.provider_store_id == mapping.provider_store_id &&
            snapshot.provider_product_id == mapping.provider_product_id &&
            snapshot.provider_variant_id == mapping.provider_variant_id &&
            snapshot.test_mode == plan_change.test_mode &&
            snapshot.provider_updated_at >= subscription.last_seen_provider_updated_at
          return if valid

          raise ProviderVariantMismatch.new(
            "Provider response did not match the requested target",
            plan_change: plan_change
          )
        end

        def mark_submitted!(plan_change, snapshot)
          transition_plan_change(plan_change) do |scoped_change|
            if scoped_change.status_pending?
              scoped_change.update!(
                status: :submitted,
                provider_updated_at: snapshot.provider_updated_at
              )
            end
          end
        end

        def transition_provider_failure!(plan_change, error)
          if definitive_failure?(error)
            mark_failed!(plan_change, failure_code(error))
          else
            transition_plan_change(plan_change) do |scoped_change|
              scoped_change.update!(status: :creation_unknown) if scoped_change.status_pending?
            end
          end
        end

        def mark_failed!(plan_change, code)
          transition_plan_change(plan_change) do |scoped_change|
            if scoped_change.status_pending?
              scoped_change.update!(
                status: :failed,
                completed_at: transition_time,
                failure_code: code
              )
            end
          end
        end

        def transition_plan_change(plan_change)
          ApplicationRecord.transaction do
            lock_and_authorize_context!
            scoped_change = Current.organization.billing_plan_changes.lock.find(plan_change.id)
            yield scoped_change
            scoped_change
          end
        end

        def terminal_result(plan_change)
          Result.new(plan_change: plan_change, compatibility: nil, duplicate: false)
        end

        def definitive_failure?(error)
          return true if error.is_a?(Billing::LemonSqueezy::Errors::VariantMismatchError)
          return true if error.is_a?(Billing::LemonSqueezy::Errors::RequestError)
          return true if error.is_a?(Billing::LemonSqueezy::Errors::ConfigurationError)

          error.is_a?(Billing::LemonSqueezy::Errors::ClientError) &&
            error.status.in?(DEFINITIVE_CLIENT_STATUSES)
        end

        def failure_code(error)
          case error
          when Billing::LemonSqueezy::Errors::VariantMismatchError
            "provider_variant_mismatch"
          when Billing::LemonSqueezy::Errors::AuthenticationError
            "provider_authentication_failed"
          when Billing::LemonSqueezy::Errors::NotFoundError
            "provider_subscription_not_found"
          when Billing::LemonSqueezy::Errors::ClientError
            "provider_rejected"
          else
            "plan_change_configuration_invalid"
          end
        end

        def transition_time
          [ Time.current, @now ].max
        end

        def lock_and_authorize_context!
          raise_not_authorized! unless @organization&.persisted? && @user&.persisted?
          raise_not_authorized! unless Current.organization&.id == @organization.id
          raise_not_authorized! unless Current.user&.id == @user.id

          Current.organization.lock!
          authoritative_user = User.lock.find_by(id: @user.id)
          membership = Current.organization.organization_memberships.lock.find_by(
            id: Current.membership&.id,
            user_id: @user.id
          )
          authorized = Current.organization.active? &&
            authoritative_user&.authentication_allowed? &&
            membership&.active? &&
            membership.role.in?(%w[owner billing])
          raise_not_authorized! unless authorized

          Current.membership = membership
        end

        def raise_not_authorized!
          raise Pundit::NotAuthorizedError, "billing plan change is not allowed"
        end
    end
  end
end
