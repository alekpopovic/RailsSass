module Billing
  module Portals
    class Open
      class Error < StandardError; end
      class NoSubscription < Error; end
      class Unavailable < Error; end
      class ProviderFailure < Error; end

      def initialize(organization:, user:, client: nil)
        @organization = organization
        @user = user
        @client = client
      end

      def call
        subscription = authorized_subscription!
        client = @client || Billing::LemonSqueezy::Client.new
        validate_provider_binding!(subscription, client)

        portal_url = client.retrieve_customer_portal_url(
          provider_subscription_id: subscription.provider_subscription_id,
          expected_customer_id: subscription.provider_customer_id
        )

        reauthorize_subscription!(subscription)
        portal_url
      rescue Billing::LemonSqueezy::Errors::Error
        raise ProviderFailure, "Customer portal is unavailable", cause: nil
      end

      private
        def authorized_subscription!
          ApplicationRecord.transaction do
            lock_and_authorize_context!
            subscription = Current.organization.billing_subscriptions
              .where(current: true)
              .lock
              .first
            raise NoSubscription, "A current subscription is required" unless subscription

            subscription
          end
        end

        def reauthorize_subscription!(subscription)
          ApplicationRecord.transaction do
            lock_and_authorize_context!
            Current.organization.billing_subscriptions
              .where(current: true)
              .lock
              .find(subscription.id)
          end
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
            membership.role.in?(%w[owner billing]) &&
            AuthorizationContext.current.authenticated?
          raise_not_authorized! unless authorized

          Current.membership = membership
        end

        def validate_provider_binding!(subscription, client)
          valid = subscription.provider == "lemon_squeezy" &&
            subscription.environment == client.environment &&
            subscription.test_mode == client.test_mode?
          raise Unavailable, "Subscription provider is unavailable" unless valid
        end

        def raise_not_authorized!
          raise Pundit::NotAuthorizedError, "billing portal is not allowed"
        end
    end
  end
end
