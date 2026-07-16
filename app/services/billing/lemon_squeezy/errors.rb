module Billing
  module LemonSqueezy
    module Errors
      class Error < StandardError
        attr_reader :status, :retry_after

        def initialize(message, status: nil, retryable: false, retry_after: nil)
          super(message)
          @status = status
          @retryable = retryable
          @retry_after = retry_after
        end

        def retryable?
          @retryable
        end
      end

      class ConfigurationError < Error; end
      class RequestError < Error; end
      class ClientError < Error; end
      class AuthenticationError < ClientError; end
      class NotFoundError < ClientError; end
      class RateLimitError < ClientError; end
      class ServerError < Error; end
      class TimeoutError < Error; end
      class ConnectionError < Error; end
      class InvalidResponseError < Error; end
      class UnexpectedResponseError < Error; end
    end
  end
end
