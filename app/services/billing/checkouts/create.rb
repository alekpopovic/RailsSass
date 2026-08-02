module Billing
  module Checkouts
    class Create
      ATTEMPT_LIFETIME = 30.minutes
      EXPIRY_GRACE_PERIOD = 10.minutes
      DEFINITIVE_CLIENT_STATUSES = [ 400, 401, 403, 404, 422 ].freeze

      Result = Data.define(:attempt, :checkout_url)

      class Error < StandardError
        attr_reader :attempt

        def initialize(message, attempt: nil)
          super(message)
          @attempt = attempt
        end
      end

      class InvalidPrice < Error; end
      class CheckoutPending < Error; end
      class ExistingSubscription < Error; end

      class ProviderFailure < Error
        def initialize(message, attempt:, ambiguous:)
          super(message, attempt: attempt)
          @ambiguous = ambiguous
        end

        def ambiguous?
          @ambiguous
        end
      end

      def initialize(organization:, user:, plan_price:, client: nil, now: Time.current)
        @organization = organization
        @user = user
        @submitted_plan_price = plan_price
        @client = client
        @now = now
      end

      def call
        client = @client || Billing::LemonSqueezy::Client.new
        plan_price, mapping = resolve_checkout_selection!(client)
        return_url = ReturnUrl.call(organization: @organization)
        attempt, raw_token = create_attempt!(
          plan_price: plan_price,
          mapping: mapping,
          client: client
        )

        provider_result = client.create_checkout(
          variant_id: mapping.provider_variant_id,
          return_url: return_url,
          expires_at: attempt.expires_at,
          checkout_attempt_token: raw_token,
          email_address: @user.email_address
        )
        ready_attempt = mark_ready!(attempt, provider_result)

        Result.new(attempt: ready_attempt, checkout_url: provider_result.checkout_url)
      rescue Billing::LemonSqueezy::Errors::Error => error
        raise unless defined?(attempt) && attempt&.persisted?

        handle_provider_failure!(attempt, error)
      rescue ActiveRecord::RecordNotUnique
        raise unless defined?(attempt) && attempt&.persisted?

        scoped_attempt = mark_creation_unknown!(attempt)
        raise ProviderFailure.new(
          "Checkout could not be confirmed safely",
          attempt: scoped_attempt,
          ambiguous: true
        ), cause: nil
      end

      private
        def resolve_checkout_selection!(client)
          raise InvalidPrice, "Checkout price is unavailable" unless @submitted_plan_price&.persisted?

          plan_price = PlanPrice.includes(:plan).find_by(id: @submitted_plan_price.id)
          mapping = Billing::ProviderPriceMapping.find_by(
            plan_price_id: plan_price&.id,
            provider: "lemon_squeezy",
            environment: client.environment,
            active: true
          )
          valid = plan_price&.active? &&
            plan_price.plan.active? &&
            !plan_price.plan.free? &&
            plan_price.lemon_variant_id.present? &&
            mapping&.checkout_eligible? &&
            mapping.provider_store_id == client.store_id
          raise InvalidPrice, "Checkout price is unavailable" unless valid

          [ plan_price, mapping ]
        end

        def create_attempt!(plan_price:, mapping:, client:)
          attempt = nil
          raw_token = nil

          ApplicationRecord.transaction do
            lock_and_authorize_context!
            plan_price.lock!
            plan_price.plan.lock!
            mapping.lock!
            revalidate_selection!(plan_price, mapping, client)
            expire_stale_attempts!
            reject_existing_subscription!
            reject_pending_attempt!

            nonce = Token.generate_nonce
            expires_at = @now + ATTEMPT_LIFETIME
            raw_token = Token.issue(
              organization: @organization,
              plan_price: plan_price,
              user: @user,
              expires_at: expires_at,
              nonce: nonce
            )
            token_digest = Token.digest_nonce(nonce)
            attempt = Current.organization.billing_checkout_attempts.create!(
              initiated_by_membership: Current.membership,
              plan_price: plan_price,
              provider: mapping.provider,
              environment: mapping.environment,
              test_mode: mapping.test_mode?,
              token_digest: token_digest,
              status: :creating,
              expires_at: expires_at
            )
            Current.organization.billing_provider_locators.create!(
              checkout_attempt: attempt,
              provider: attempt.provider,
              environment: attempt.environment,
              token_digest: token_digest,
              status: :unresolved
            )
            AuditEvents::Record.call(
              organization: Current.organization,
              actor_user: @user,
              action: "billing.checkout.started",
              subject: attempt,
              metadata: {
                plan_price_id: plan_price.id,
                plan_key: plan_price.plan.key,
                environment: attempt.environment,
                test_mode: attempt.test_mode
              }
            )
          end

          [ attempt, raw_token ]
        rescue ActiveRecord::RecordNotUnique
          pending = pending_attempt
          raise CheckoutPending.new("A checkout is already pending", attempt: pending) if pending

          raise
        end

        def lock_and_authorize_context!
          authorized_root = @organization&.persisted? &&
            @user&.persisted? &&
            Current.organization&.id == @organization.id &&
            Current.user&.id == @user.id
          raise_not_authorized! unless authorized_root

          Current.organization.lock!
          authoritative_user = User.lock.find_by(id: @user.id)
          membership = Current.organization.organization_memberships
            .where(id: Current.membership&.id, user_id: @user.id)
            .lock
            .first
          authorized = Current.organization.active? &&
            authoritative_user&.authentication_allowed? &&
            membership&.active? &&
            membership.role.in?(%w[owner billing]) &&
            AuthorizationContext.current.authenticated?
          raise_not_authorized! unless authorized

          Current.membership = membership
        end

        def revalidate_selection!(plan_price, mapping, client)
          valid = plan_price.active? &&
            plan_price.plan.active? &&
            !plan_price.plan.free? &&
            plan_price.lemon_variant_id.present? &&
            mapping.active? &&
            mapping.plan_price_id == plan_price.id &&
            mapping.provider == "lemon_squeezy" &&
            mapping.environment == client.environment &&
            mapping.provider_store_id == client.store_id
          raise InvalidPrice, "Checkout price is unavailable" unless valid
        end

        def expire_stale_attempts!
          Current.organization.billing_checkout_attempts
            .pending
            .lock
            .each do |attempt|
              next if @now < attempt.expires_at + EXPIRY_GRACE_PERIOD

              attempt.update!(status: :expired, completed_at: @now)
            end
        end

        def reject_existing_subscription!
          subscription = Current.organization.billing_subscriptions
            .where(current: true)
            .lock
            .first
          return if subscription.nil? || subscription.status_expired?

          raise ExistingSubscription, "The organization already has a subscription"
        end

        def reject_pending_attempt!
          attempt = pending_attempt(lock: true)
          return unless attempt

          raise CheckoutPending.new("A checkout is already pending", attempt: attempt)
        end

        def pending_attempt(lock: false)
          scope = Current.organization.billing_checkout_attempts
            .pending
            .order(created_at: :desc, id: :desc)
          scope = scope.lock if lock
          scope.first
        end

        def mark_ready!(attempt, provider_result)
          ApplicationRecord.transaction do
            scoped_attempt = Current.organization.billing_checkout_attempts.lock.find(attempt.id)
            if scoped_attempt.status_creating?
              scoped_attempt.update!(
                status: :ready,
                provider_checkout_id: provider_result.provider_checkout_id
              )
            end
            scoped_attempt
          end
        end

        def handle_provider_failure!(attempt, error)
          definitive = definitive_failure?(error)
          scoped_attempt = definitive ? mark_failed!(attempt, error) : mark_creation_unknown!(attempt)
          raise ProviderFailure.new(
            "Checkout could not be created safely",
            attempt: scoped_attempt,
            ambiguous: !definitive
          ), cause: nil
        end

        def mark_creation_unknown!(attempt)
          transition_attempt(attempt) do |scoped_attempt|
            scoped_attempt.update!(status: :creation_unknown) if scoped_attempt.status_creating?
          end
        end

        def mark_failed!(attempt, error)
          transition_attempt(attempt) do |scoped_attempt|
            if scoped_attempt.status_creating?
              scoped_attempt.update!(
                status: :failed,
                completed_at: Time.current,
                failure_code: failure_code(error)
              )
              locator = Current.organization.billing_provider_locators.lock.find_by!(
                billing_checkout_attempt_id: scoped_attempt.id
              )
              locator.update!(
                status: :definitive_creation_failure,
                resolved_at: Time.current
              )
            end
          end
        end

        def transition_attempt(attempt)
          ApplicationRecord.transaction do
            scoped_attempt = Current.organization.billing_checkout_attempts.lock.find(attempt.id)
            yield scoped_attempt
            scoped_attempt
          end
        end

        def definitive_failure?(error)
          return true if error.is_a?(Billing::LemonSqueezy::Errors::RequestError)
          return true if error.is_a?(Billing::LemonSqueezy::Errors::ConfigurationError)

          error.is_a?(Billing::LemonSqueezy::Errors::ClientError) &&
            error.status.in?(DEFINITIVE_CLIENT_STATUSES)
        end

        def failure_code(error)
          case error
          when Billing::LemonSqueezy::Errors::AuthenticationError
            "provider_authentication_failed"
          when Billing::LemonSqueezy::Errors::RateLimitError
            "provider_rate_limited"
          when Billing::LemonSqueezy::Errors::NotFoundError
            "provider_mapping_rejected"
          when Billing::LemonSqueezy::Errors::ClientError
            "provider_rejected"
          else
            "checkout_configuration_invalid"
          end
        end

        def raise_not_authorized!
          raise Pundit::NotAuthorizedError, "billing checkout is not allowed"
        end
    end
  end
end
