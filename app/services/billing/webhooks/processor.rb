require "time"

module Billing
  module Webhooks
    class Processor
      PROVIDER = "lemon_squeezy"
      PROCESSING_LEASE = 15.minutes
      CLOCK_SKEW = 5.minutes
      MAX_PROCESSING_ATTEMPTS = 8
      CREATED_EVENT = "subscription_created"
      PLAN_CHANGE_EVENT = "subscription_updated"
      RETRYABLE_ERROR_CODES = %w[
        provider_temporarily_unavailable
        database_temporarily_unavailable
        subscription_correlation_pending
      ].freeze
      CRITICAL_SNAPSHOT_KEYS = %w[
        card_brand card_last_four ends_at pause provider_created_at provider_customer_id
        provider_product_id provider_store_id provider_subscription_id
        provider_updated_at provider_variant_id renews_at status test_mode
        trial_ends_at
      ].freeze

      Result = Data.define(:status, :event, :subscription) do
        def processed?
          status == :processed
        end
      end

      class Error < StandardError
        attr_reader :error_code

        def initialize(error_code)
          @error_code = error_code.to_s
          super(@error_code)
        end
      end

      class RetryableError < Error; end
      class PermanentError < Error; end

      def self.call(webhook_event_id:, **options)
        new(webhook_event_id:, **options).call
      end

      def initialize(webhook_event_id:, client: nil, now: Time.current)
        @webhook_event_id = webhook_event_id
        @client = client
        @now = now
      end

      def call
        event = claim_event
        return Result.new(status: :noop, event: terminal_event, subscription: nil) unless event

        validate_event_contract!(event)
        client = @client || Billing::LemonSqueezy::Client.new
        subscription_id = event.payload["provider_subscription_id"].to_s
        raise PermanentError, "invalid_subscription_reference" if subscription_id.blank?

        snapshot = client.retrieve_subscription_snapshot(
          provider_subscription_id: subscription_id
        )
        validate_snapshot_authority!(event, snapshot, client)

        if event.event_name == CREATED_EVENT
          project_created(event, snapshot)
        else
          project_existing(event, snapshot)
        end
      rescue Billing::LemonSqueezy::Errors::Error => error
        handle_provider_error(error)
      rescue RetryableError => error
        handle_retryable_failure(error.error_code)
      rescue PermanentError => error
        mark_failed(error.error_code)
      rescue ActiveRecord::Deadlocked, ActiveRecord::SerializationFailure => error
        Rails.logger.warn(
          "billing_webhook_projection_retry event_id=#{@webhook_event_id} " \
            "error_class=#{error.class.name}"
        )
        handle_retryable_failure("database_temporarily_unavailable")
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
        Rails.logger.warn(
          "billing_webhook_projection_rejected event_id=#{@webhook_event_id} " \
            "error_class=#{error.class.name}"
        )
        mark_failed("projection_conflict")
      ensure
        Current.reset
      end

      private
        def claim_event
          ApplicationRecord.transaction do
            event = Billing::WebhookEvent.lock.find(@webhook_event_id)
            if retry_exhausted_processing?(event)
              event.update!(
                status: :failed,
                processed_at: @now,
                failed_at: @now,
                error_code: "retry_exhausted",
                error_class: PermanentError.name,
                error_message: "Webhook projection retries were exhausted",
                payload: event.payload.merge("reason_code" => "retry_exhausted")
              )
              next
            end
            return unless claimable?(event)

            event.update!(
              status: :processing,
              processing_started_at: @now,
              processed_at: nil,
              failed_at: nil,
              error_code: nil,
              error_class: nil,
              error_message: nil,
              attempts_count: event.attempts_count + 1
            )
            event
          end
        end

        def claimable?(event)
          return false unless event.provider == PROVIDER &&
            event.verified_at? &&
            event.ingress_version == Billing::WebhookEvent::CURRENT_INGRESS_VERSION
          return true if event.status_received?
          if event.status_failed? && event.error_code.in?(RETRYABLE_ERROR_CODES)
            return event.attempts_count < MAX_PROCESSING_ATTEMPTS
          end

          event.status_processing? &&
            event.attempts_count < MAX_PROCESSING_ATTEMPTS &&
            event.processing_started_at.present? &&
            event.processing_started_at <= @now - PROCESSING_LEASE
        end

        def retry_exhausted_processing?(event)
          event.status_processing? &&
            event.attempts_count >= MAX_PROCESSING_ATTEMPTS &&
            event.processing_started_at.present? &&
            event.processing_started_at <= @now - PROCESSING_LEASE
        end

        def terminal_event
          Billing::WebhookEvent.find_by(id: @webhook_event_id)
        end

        def validate_event_contract!(event)
          expected_resource_type = if event.event_name.in?(Billing::Webhooks::Receive::PAYMENT_EVENTS)
            "subscription-invoices"
          elsif event.event_name.in?(Billing::Webhooks::Receive::SUBSCRIPTION_EVENTS)
            "subscriptions"
          end
          valid = expected_resource_type.present? &&
            event.external_resource_type == expected_resource_type &&
            event.external_resource_id.present? &&
            event.test_mode.in?([ true, false ]) &&
            event.payload["event_name"] == event.event_name &&
            event.payload["resource_type"] == expected_resource_type
          raise PermanentError, "invalid_event_contract" unless valid
        end

        def validate_snapshot_authority!(event, snapshot, client)
          expected_subscription_id = event.payload["provider_subscription_id"].to_s
          raise PermanentError, "subscription_identity_mismatch" unless snapshot.provider_subscription_id == expected_subscription_id
          raise PermanentError, "environment_mismatch" unless event.test_mode == snapshot.test_mode

          if client.respond_to?(:environment) && client.environment.present?
            raise PermanentError, "environment_mismatch" unless client.environment.to_s == event.environment
          end
          if client.respond_to?(:store_id) && client.store_id.present?
            raise PermanentError, "store_mismatch" unless client.store_id.to_s == snapshot.provider_store_id
          end
          if snapshot.provider_updated_at > @now + CLOCK_SKEW
            raise PermanentError, "provider_timestamp_in_future"
          end
        end

        def project_created(event, snapshot)
          context = verified_checkout_context(event)
          locator = Billing::ProviderLocator.find_by(
            provider: event.provider,
            environment: event.environment,
            token_digest: context.fetch(:token_digest)
          )
          raise PermanentError, "checkout_context_not_found" unless locator

          organization = Organization.find_by(id: locator.organization_id)
          raise PermanentError, "checkout_context_not_found" unless organization

          Current.organization = organization
          ApplicationRecord.transaction do
            organization.lock!
            locked_event = locked_processing_event!
            scoped_locator = Current.organization.billing_provider_locators.lock.find(locator.id)
            attempt = Current.organization.billing_checkout_attempts.lock.find(
              scoped_locator.billing_checkout_attempt_id
            )
            validate_checkout_context!(locked_event, scoped_locator, attempt, context, snapshot)

            if scoped_locator.billing_subscription_id.present?
              subscription = Current.organization.billing_subscriptions.lock.find(
                scoped_locator.billing_subscription_id
              )
              validate_locator_subscription!(scoped_locator, subscription, snapshot)
              next apply_existing_snapshot!(locked_event, subscription, snapshot)
            end

            mapping = attempt.provider_price_mapping
            mapping.lock!
            validate_created_mapping!(attempt, mapping, snapshot)
            unless snapshot.known_status?
              next fail_in_transaction!(
                locked_event,
                "unknown_subscription_status",
                snapshot: snapshot
              )
            end
            unless status_timestamps_valid?(snapshot)
              next fail_in_transaction!(
                locked_event,
                "invalid_subscription_timestamps",
                snapshot: snapshot
              )
            end

            subscription = Current.organization.billing_subscriptions
              .where(
                provider: locked_event.provider,
                environment: locked_event.environment,
                provider_subscription_id: snapshot.provider_subscription_id
              )
              .lock
              .first
            if subscription
              unless subscription.current?
                next fail_in_transaction!(locked_event, "archived_subscription_conflict")
              end
              validate_existing_created_subscription!(attempt, subscription, snapshot)
            end

            current_subscription = Current.organization.billing_subscriptions
              .where(current: true)
              .lock
              .first
            if current_subscription && current_subscription.provider_subscription_id != snapshot.provider_subscription_id
              unless current_subscription.status_expired?
                next fail_in_transaction!(locked_event, "second_current_subscription")
              end

              current_subscription.update!(current: false, archived_at: @now)
            end

            supersede_competing_attempts!(attempt)
            customer = upsert_customer!(locked_event, snapshot)

            if subscription
              subscription.assign_attributes(existing_snapshot_attributes(subscription, snapshot, mapping.plan_price))
              subscription.save!
            else
              subscription = Current.organization.billing_subscriptions.create!(
                new_subscription_attributes(
                  event: locked_event,
                  snapshot: snapshot,
                  customer: customer,
                  plan_price: mapping.plan_price,
                  checkout_attempt: attempt
                )
              )
            end

            complete_checkout_authority!(
              locator: scoped_locator,
              attempt: attempt,
              subscription: subscription,
              snapshot: snapshot
            )
            complete_event!(locked_event, snapshot, subscription: subscription)
          end
        end

        def project_existing(event, snapshot)
          locator = Billing::ProviderLocator.find_by(
            provider: event.provider,
            environment: event.environment,
            provider_subscription_id: snapshot.provider_subscription_id
          )
          unless locator&.billing_subscription_id
            raise RetryableError, "subscription_correlation_pending"
          end

          organization = Organization.find_by(id: locator.organization_id)
          raise PermanentError, "subscription_locator_invalid" unless organization

          Current.organization = organization
          ApplicationRecord.transaction do
            organization.lock!
            locked_event = locked_processing_event!
            scoped_locator = Current.organization.billing_provider_locators.lock.find(locator.id)
            subscription = Current.organization.billing_subscriptions.lock.find(
              scoped_locator.billing_subscription_id
            )
            validate_locator_subscription!(scoped_locator, subscription, snapshot)
            apply_existing_snapshot!(locked_event, subscription, snapshot)
          end
        end

        def apply_existing_snapshot!(event, subscription, snapshot)
          last_seen_at = subscription.last_seen_provider_updated_at
          incoming_at = snapshot.provider_updated_at

          if incoming_at < last_seen_at
            return ignore_event!(event, snapshot, "stale_provider_snapshot", subscription: subscription)
          end

          if incoming_at == last_seen_at
            if critical_snapshot(subscription.raw_payload) == critical_snapshot(snapshot.critical_attributes)
              return complete_event!(event, snapshot, subscription: subscription)
            end

            subscription.update!(sync_state: :invalid)
            return fail_in_transaction!(
              event,
              "provider_timestamp_conflict",
              snapshot: snapshot,
              subscription: subscription
            )
          end

          mapping = provider_mapping(snapshot, event)
          unless mapping
            subscription.update!(
              last_seen_provider_updated_at: incoming_at,
              sync_state: :mapping_error
            )
            return fail_in_transaction!(
              event,
              "unknown_provider_variant",
              snapshot: snapshot,
              subscription: subscription
            )
          end

          unless snapshot.known_status?
            subscription.update!(
              status: :unknown,
              trial_ends_at: nil,
              ends_at: nil,
              past_due_started_at: nil,
              provider_updated_at: incoming_at,
              last_seen_provider_updated_at: incoming_at,
              sync_state: :invalid,
              raw_payload: subscription_payload(snapshot, event_name: event.event_name)
            )
            return fail_in_transaction!(
              event,
              "unknown_subscription_status",
              snapshot: snapshot,
              subscription: subscription
            )
          end

          unless status_timestamps_valid?(snapshot)
            subscription.update!(
              last_seen_provider_updated_at: incoming_at,
              sync_state: :invalid
            )
            return fail_in_transaction!(
              event,
              "invalid_subscription_timestamps",
              snapshot: snapshot,
              subscription: subscription
            )
          end

          upsert_customer!(event, snapshot, expected_customer: subscription.billing_customer)
          subscription.assign_attributes(existing_snapshot_attributes(subscription, snapshot, mapping.plan_price))
          subscription.save!
          reconcile_plan_change!(event, subscription, mapping, incoming_at)
          complete_event!(event, snapshot, subscription: subscription)
        end

        def reconcile_plan_change!(event, subscription, mapping, incoming_at)
          return unless event.event_name == PLAN_CHANGE_EVENT

          plan_change = Current.organization.billing_plan_changes
            .open
            .where(billing_subscription_id: subscription.id)
            .lock
            .first
          return unless plan_change
          return if plan_change.provider_updated_at && incoming_at < plan_change.provider_updated_at
          return if mapping.plan_price_id == plan_change.from_plan_price_id

          status = mapping.plan_price_id == plan_change.to_plan_price_id ? :applied : :superseded
          plan_change.update!(
            status: status,
            provider_updated_at: incoming_at,
            completed_at: @now,
            failure_code: nil
          )
        end

        def verified_checkout_context(event)
          payload = event.payload
          expires_at = strict_time(payload["checkout_expires_at"])
          plan_price_id = strict_positive_integer(payload["checkout_plan_price_id"])
          user_id = strict_positive_integer(payload["checkout_user_id"])
          organization_public_id = payload["checkout_organization_public_id"].to_s
          token_digest = payload["checkout_token_digest"].to_s
          valid = Billing::Checkouts::Token::UUID_PATTERN.match?(organization_public_id) &&
            Billing::CheckoutAttempt::TOKEN_DIGEST_PATTERN.match?(token_digest) &&
            plan_price_id && user_id && expires_at && expires_at > event.received_at
          raise PermanentError, "invalid_checkout_context" unless valid

          {
            organization_public_id: organization_public_id,
            plan_price_id: plan_price_id,
            user_id: user_id,
            token_digest: token_digest,
            expires_at: expires_at
          }
        end

        def validate_checkout_context!(event, locator, attempt, context, snapshot)
          valid = event.organization_id.nil? || event.organization_id == Current.organization.id
          valid &&= locator.token_digest == context.fetch(:token_digest)
          valid &&= locator.checkout_attempt.id == attempt.id
          valid &&= attempt.token_digest == context.fetch(:token_digest)
          valid &&= attempt.plan_price_id == context.fetch(:plan_price_id)
          valid &&= attempt.initiated_by_membership.user_id == context.fetch(:user_id)
          valid &&= Current.organization.public_id == context.fetch(:organization_public_id)
          valid &&= (attempt.expires_at - context.fetch(:expires_at)).abs <= 1.second
          valid &&= attempt.test_mode == snapshot.test_mode
          valid &&= attempt.provider == event.provider
          valid &&= attempt.environment == event.environment
          valid &&= !locator.status_definitive_creation_failure?
          if snapshot.created_at
            valid &&= snapshot.created_at <= attempt.expires_at + CLOCK_SKEW
            valid &&= snapshot.created_at >= attempt.created_at - CLOCK_SKEW
          end
          raise PermanentError, "checkout_context_mismatch" unless valid
        end

        def validate_created_mapping!(attempt, mapping, snapshot)
          valid = mapping.plan_price_id == attempt.plan_price_id &&
            mapping.provider == attempt.provider &&
            mapping.environment == attempt.environment &&
            mapping.provider_store_id == snapshot.provider_store_id &&
            mapping.provider_product_id == snapshot.provider_product_id &&
            mapping.provider_variant_id == snapshot.provider_variant_id &&
            attempt.plan_price.lemon_variant_id == snapshot.provider_variant_id
          raise PermanentError, "checkout_variant_mismatch" unless valid
        end

        def validate_locator_subscription!(locator, subscription, snapshot)
          valid = locator.provider_subscription_id == snapshot.provider_subscription_id &&
            locator.organization_id == subscription.organization_id &&
            locator.provider == subscription.provider &&
            locator.environment == subscription.environment &&
            subscription.provider_subscription_id == snapshot.provider_subscription_id &&
            subscription.provider_customer_id == snapshot.provider_customer_id &&
            subscription.test_mode == snapshot.test_mode &&
            subscription.origin_checkout_attempt_id == locator.billing_checkout_attempt_id
          raise PermanentError, "subscription_locator_invalid" unless valid
        end

        def validate_existing_created_subscription!(attempt, subscription, snapshot)
          valid = subscription.origin_checkout_attempt_id == attempt.id &&
            subscription.provider_customer_id == snapshot.provider_customer_id &&
            subscription.test_mode == snapshot.test_mode
          raise PermanentError, "subscription_origin_mismatch" unless valid
        end

        def supersede_competing_attempts!(attempt)
          Current.organization.billing_checkout_attempts
            .pending
            .where.not(id: attempt.id)
            .lock
            .find_each do |competing_attempt|
              competing_attempt.update!(status: :superseded, completed_at: @now)
            end
        end

        def status_timestamps_valid?(snapshot)
          return false if snapshot.provider_status == "on_trial" && snapshot.trial_ends_at.nil?
          return false if snapshot.provider_status == "cancelled" && snapshot.ends_at.nil?

          true
        end

        def provider_mapping(snapshot, event)
          Billing::ProviderPriceMapping.find_by(
            provider: event.provider,
            environment: event.environment,
            provider_store_id: snapshot.provider_store_id,
            provider_product_id: snapshot.provider_product_id,
            provider_variant_id: snapshot.provider_variant_id
          )
        end

        def upsert_customer!(event, snapshot, expected_customer: nil)
          customer = Current.organization.billing_customers
            .where(
              provider: event.provider,
              environment: event.environment,
              provider_customer_id: snapshot.provider_customer_id
            )
            .lock
            .first
          customer ||= Current.organization.billing_customers.create!(
            provider: event.provider,
            environment: event.environment,
            provider_customer_id: snapshot.provider_customer_id,
            test_mode: snapshot.test_mode,
            provider_updated_at: snapshot.provider_updated_at
          )
          if expected_customer && customer.id != expected_customer.id
            raise PermanentError, "customer_identity_mismatch"
          end
          if customer.provider_updated_at.nil? || customer.provider_updated_at < snapshot.provider_updated_at
            customer.update!(provider_updated_at: snapshot.provider_updated_at)
          end
          customer
        end

        def new_subscription_attributes(event:, snapshot:, customer:, plan_price:, checkout_attempt:)
          {
            billing_customer: customer,
            plan_price: plan_price,
            origin_plan_price: plan_price,
            origin_checkout_attempt: checkout_attempt,
            provider: event.provider,
            environment: event.environment,
            provider_subscription_id: snapshot.provider_subscription_id,
            provider_customer_id: snapshot.provider_customer_id,
            status: snapshot.provider_status,
            current: true,
            trial_ends_at: snapshot.trial_ends_at,
            renews_at: snapshot.renews_at,
            ends_at: snapshot.ends_at,
            past_due_started_at: past_due_started_at(nil, snapshot),
            provider_updated_at: snapshot.provider_updated_at,
            last_seen_provider_updated_at: snapshot.provider_updated_at,
            sync_state: :synced,
            pause: snapshot.pause,
            card_brand: snapshot.card_brand,
            card_last_four: snapshot.card_last_four,
            test_mode: snapshot.test_mode,
            raw_payload: subscription_payload(snapshot, event_name: event.event_name),
            archived_at: nil
          }
        end

        def existing_snapshot_attributes(subscription, snapshot, plan_price)
          {
            plan_price: plan_price,
            status: snapshot.provider_status,
            trial_ends_at: snapshot.trial_ends_at,
            renews_at: snapshot.renews_at,
            ends_at: snapshot.ends_at,
            past_due_started_at: past_due_started_at(subscription, snapshot),
            provider_updated_at: snapshot.provider_updated_at,
            last_seen_provider_updated_at: snapshot.provider_updated_at,
            sync_state: :synced,
            pause: snapshot.pause,
            card_brand: snapshot.card_brand,
            card_last_four: snapshot.card_last_four,
            raw_payload: subscription_payload(snapshot)
          }
        end

        def past_due_started_at(subscription, snapshot)
          return unless snapshot.provider_status == "past_due"
          return subscription.past_due_started_at if subscription&.status_past_due? && subscription.past_due_started_at

          snapshot.provider_updated_at
        end

        def subscription_payload(snapshot, event_name: nil)
          snapshot.sanitized_payload(event_name: event_name).compact
        end

        def critical_snapshot(payload)
          payload.slice(*CRITICAL_SNAPSHOT_KEYS)
        end

        def complete_checkout_authority!(locator:, attempt:, subscription:, snapshot:)
          now = @now
          unless attempt.status_completed?
            attempt.update!(
              status: :completed,
              completed_at: now,
              token_consumed_at: now,
              failure_code: nil
            )
          end
          locator.update!(
            status: :consumed,
            resolved_at: locator.resolved_at || now,
            provider_subscription_id: snapshot.provider_subscription_id,
            billing_subscription_id: subscription.id
          )
        end

        def complete_event!(event, snapshot, subscription:)
          event.update!(
            organization: Current.organization,
            status: :processed,
            processed_at: @now,
            failed_at: nil,
            provider_updated_at: snapshot.provider_updated_at,
            payload: event.payload.merge(snapshot.sanitized_payload(event_name: event.event_name)),
            error_code: nil,
            error_class: nil,
            error_message: nil
          )
          Result.new(status: :processed, event: event, subscription: subscription)
        end

        def ignore_event!(event, snapshot, reason_code, subscription:)
          event.update!(
            organization: Current.organization,
            status: :ignored,
            processed_at: @now,
            failed_at: nil,
            provider_updated_at: snapshot.provider_updated_at,
            payload: event.payload.merge(
              snapshot.sanitized_payload(event_name: event.event_name),
              "reason_code" => reason_code
            ),
            error_code: nil,
            error_class: nil,
            error_message: nil
          )
          Result.new(status: :ignored, event: event, subscription: subscription)
        end

        def fail_in_transaction!(event, error_code, snapshot: nil, subscription: nil)
          payload = event.payload.merge("reason_code" => error_code)
          payload.merge!(snapshot.sanitized_payload(event_name: event.event_name)) if snapshot
          event.update!(
            organization: Current.organization,
            status: :failed,
            processed_at: @now,
            failed_at: @now,
            provider_updated_at: snapshot&.provider_updated_at,
            payload: payload,
            error_code: error_code,
            error_class: PermanentError.name,
            error_message: "Webhook projection was rejected safely"
          )
          Result.new(status: :failed, event: event, subscription: subscription)
        end

        def locked_processing_event!
          event = Billing::WebhookEvent.lock.find(@webhook_event_id)
          raise PermanentError, "webhook_claim_lost" unless event.status_processing?

          event
        end

        def handle_provider_error(error)
          retryable = error.retryable? || error.is_a?(Billing::LemonSqueezy::Errors::NotFoundError)
          return handle_retryable_failure("provider_temporarily_unavailable") if retryable

          mark_failed("provider_response_invalid")
        end

        def handle_retryable_failure(error_code)
          event = Billing::WebhookEvent.find_by(id: @webhook_event_id)
          if event&.attempts_count.to_i >= MAX_PROCESSING_ATTEMPTS
            return mark_failed("retry_exhausted")
          end

          mark_failed(error_code, retryable: true)
          raise RetryableError, error_code
        end

        def mark_failed(error_code, retryable: false)
          event = ApplicationRecord.transaction do
            locked = Billing::WebhookEvent.lock.find_by(id: @webhook_event_id)
            next unless locked&.status_processing?

            locked.update!(
              status: :failed,
              processed_at: @now,
              failed_at: @now,
              error_code: error_code,
              error_class: retryable ? RetryableError.name : PermanentError.name,
              error_message: retryable ?
                "Webhook projection will be retried" :
                "Webhook projection was rejected safely",
              payload: locked.payload.merge("reason_code" => error_code)
            )
            locked
          end
          Result.new(status: :failed, event: event || terminal_event, subscription: nil)
        end

        def strict_time(value)
          return unless value.is_a?(String)

          Time.iso8601(value)
        rescue ArgumentError
          nil
        end

        def strict_positive_integer(value)
          integer = Integer(value.to_s, 10)
          integer if integer.positive?
        rescue ArgumentError, TypeError
          nil
        end
    end
  end
end
