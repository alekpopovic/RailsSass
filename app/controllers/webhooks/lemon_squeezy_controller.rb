module Webhooks
  class LemonSqueezyController < ActionController::Metal
    include AbstractController::Callbacks
    include ActionController::RateLimiting

    RATE_LIMIT = 300
    RATE_LIMIT_WINDOW = 1.minute
    RATE_LIMIT_NAME = "lemon-squeezy-webhook-ingress"

    rate_limit to: RATE_LIMIT,
      within: RATE_LIMIT_WINDOW,
      by: -> { request.remote_ip },
      with: :respond_rate_limited,
      store: Rails.cache,
      name: RATE_LIMIT_NAME

    def create
      result = Billing::Webhooks::Receive.call(
        body: request.body,
        signature: request.get_header("HTTP_X_SIGNATURE"),
        content_type: request.content_type,
        request_id: request.request_id
      )

      self.status = result.status
      self.content_type = "application/json"
      self.response_body = ""
    end

    private
      def respond_rate_limited
        response.set_header("Retry-After", RATE_LIMIT_WINDOW.to_i.to_s)
        self.status = :too_many_requests
        self.content_type = "application/json"
        self.response_body = ""
      end
  end
end
