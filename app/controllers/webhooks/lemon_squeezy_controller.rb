module Webhooks
  class LemonSqueezyController < ActionController::Metal
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
  end
end
