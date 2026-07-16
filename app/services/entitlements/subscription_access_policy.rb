module Entitlements
  class SubscriptionAccessPolicy
    def initialize(
      subscription:,
      now: Time.current,
      past_due_grace_period: Rails.application.config.x.entitlements.past_due_grace_period
    )
      @subscription = subscription
      @now = now
      @past_due_grace_seconds = normalize_grace_period(past_due_grace_period)
    end

    def call
      return denied(:no_current_subscription) unless subscription
      return denied(:subscription_not_current) unless subscription.current? && subscription.archived_at.nil?

      case subscription.status
      when "on_trial"
        allowed(:subscription_on_trial)
      when "active"
        allowed(:subscription_active)
      when "cancelled"
        cancelled_result
      when "past_due"
        past_due_result
      when "paused"
        denied(:subscription_paused)
      when "unpaid"
        denied(:subscription_unpaid)
      when "expired"
        denied(:subscription_expired)
      else
        denied(:subscription_unknown_status)
      end
    end

    private
      attr_reader :subscription, :now, :past_due_grace_seconds

      def cancelled_result
        return denied(:subscription_cancelled_missing_end) unless subscription.ends_at

        if now < subscription.ends_at
          allowed(
            :subscription_cancelled_with_access,
            access_ends_at: subscription.ends_at
          )
        else
          denied(
            :subscription_cancelled_ended,
            access_ended_at: subscription.ends_at
          )
        end
      end

      def past_due_result
        started_at = subscription.past_due_started_at
        return denied(:subscription_past_due_missing_start) unless started_at
        return denied(:subscription_past_due_future_start) if started_at > now

        access_ends_at = started_at + past_due_grace_seconds
        if now < access_ends_at
          allowed(:subscription_past_due_grace, access_ends_at: access_ends_at)
        else
          denied(:subscription_past_due_grace_expired, access_ended_at: access_ends_at)
        end
      end

      def allowed(reason_code, details = {})
        Result.new(allowed: true, reason_code: reason_code, details: details)
      end

      def denied(reason_code, details = {})
        Result.new(allowed: false, reason_code: reason_code, details: details)
      end

      def normalize_grace_period(duration)
        seconds = Float(duration)
        return seconds if seconds.finite? && seconds >= 0

        raise ArgumentError, "past-due grace period must be a finite non-negative duration"
      rescue TypeError, ArgumentError
        raise ArgumentError, "past-due grace period must be a finite non-negative duration"
      end
  end
end
