require "faraday"
require "json"
require "timeout"

module Billing
  module LemonSqueezy
    class Client
      BASE_URL = "https://api.lemonsqueezy.com"
      MEDIA_TYPE = "application/vnd.api+json"
      DEFAULT_OPEN_TIMEOUT = 2
      DEFAULT_READ_TIMEOUT = 5
      MAX_RESPONSE_BYTES = 1_048_576
      MAX_RETRY_AFTER_SECONDS = 3_600
      SAFE_PROVIDER_ID = /\A[a-zA-Z0-9_-]{1,128}\z/
      SAFE_PATH = /\A\/v1\/[a-zA-Z0-9_.\/-]+\z/

      attr_reader :store_id, :open_timeout, :read_timeout

      def initialize(
        api_key: nil,
        store_id: nil,
        open_timeout: DEFAULT_OPEN_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT,
        env: ENV,
        credentials: Rails.application.credentials
      )
        @api_key = configuration_value(api_key, env["LEMON_SQUEEZY_API_KEY"], credential_value(credentials, :api_key))
        @store_id = configuration_value(store_id, env["LEMON_SQUEEZY_STORE_ID"], credential_value(credentials, :store_id))
        @open_timeout = positive_timeout(open_timeout, "connect")
        @read_timeout = positive_timeout(read_timeout, "read")

        raise Errors::ConfigurationError, "Lemon Squeezy API key is not configured" unless @api_key
        raise Errors::ConfigurationError, "Lemon Squeezy store ID is not configured" unless @store_id
      end

      def retrieve_subscription(provider_subscription_id:)
        provider_subscription_id = provider_subscription_id.to_s
        unless SAFE_PROVIDER_ID.match?(provider_subscription_id)
          raise Errors::RequestError, "Invalid Lemon Squeezy subscription ID"
        end

        request(method: :get, path: "/v1/subscriptions/#{provider_subscription_id}")
      end

      def inspect
        "#<#{self.class.name} configured=true>"
      end

      private
        def request(method:, path:, body: nil)
          method = method.to_sym if method.respond_to?(:to_sym)
          unless %i[get post patch delete].include?(method)
            raise Errors::RequestError, "Unsupported Lemon Squeezy request method"
          end
          unless safe_path?(path)
            raise Errors::RequestError, "Invalid Lemon Squeezy request path"
          end

          response = connection.public_send(method, path) do |request|
            request.headers["Authorization"] = "Bearer #{@api_key}"
            request.headers["Accept"] = MEDIA_TYPE
            request.headers["Content-Type"] = MEDIA_TYPE
            request.body = serialize_body(body) unless body.nil?
          end

          parse_response(response)
        rescue Faraday::TimeoutError
          raise Errors::TimeoutError.new(
            "Lemon Squeezy request timed out",
            retryable: true
          ), cause: nil
        rescue Faraday::ConnectionFailed, Faraday::SSLError => error
          error_class, message = if error.cause.is_a?(Timeout::Error)
            [ Errors::TimeoutError, "Lemon Squeezy request timed out" ]
          else
            [ Errors::ConnectionError, "Lemon Squeezy connection failed" ]
          end

          raise error_class.new(message, retryable: true), cause: nil
        end

        def connection
          @connection ||= Faraday.new(
            url: BASE_URL,
            request: { open_timeout: open_timeout, timeout: read_timeout }
          ) do |faraday|
            faraday.adapter Faraday.default_adapter
          end
        end

        def serialize_body(body)
          JSON.generate(body)
        rescue JSON::GeneratorError, TypeError
          raise Errors::RequestError.new("Invalid Lemon Squeezy request body"), cause: nil
        end

        def parse_response(response)
          status = response.status.to_i

          return nil if status == 204
          return parse_success(response.body, status:) if status.between?(200, 299)

          raise_response_error(status, response.headers)
        end

        def parse_success(body, status:)
          if body.nil? || body.empty? || body.bytesize > MAX_RESPONSE_BYTES
            raise Errors::InvalidResponseError.new(
              "Lemon Squeezy returned an invalid response",
              status:
            )
          end

          parsed = JSON.parse(body)
          return parsed if parsed.is_a?(Hash)

          raise Errors::InvalidResponseError.new(
            "Lemon Squeezy returned an invalid response",
            status:
          )
        rescue JSON::ParserError
          raise Errors::InvalidResponseError.new(
            "Lemon Squeezy returned invalid JSON",
            status:
          ), cause: nil
        end

        def raise_response_error(status, headers)
          error = case status
          when 401, 403
            Errors::AuthenticationError.new("Lemon Squeezy authentication failed", status:)
          when 404
            Errors::NotFoundError.new("Lemon Squeezy resource was not found", status:)
          when 429
            Errors::RateLimitError.new(
              "Lemon Squeezy rate limit was exceeded",
              status:,
              retryable: true,
              retry_after: retry_after_seconds(headers)
            )
          when 400..499
            Errors::ClientError.new("Lemon Squeezy rejected the request", status:)
          when 500..599
            Errors::ServerError.new("Lemon Squeezy server error", status:, retryable: true)
          else
            Errors::UnexpectedResponseError.new("Unexpected Lemon Squeezy response", status:)
          end

          raise error, cause: nil
        end

        def retry_after_seconds(headers)
          value = headers["retry-after"].to_s
          return unless /\A\d+\z/.match?(value)

          [ value.to_i, MAX_RETRY_AFTER_SECONDS ].min
        end

        def safe_path?(path)
          return false unless path.is_a?(String) && SAFE_PATH.match?(path)

          path.split("/").none? { |segment| segment == "." || segment == ".." }
        end

        def configuration_value(*candidates)
          candidates.each do |candidate|
            value = candidate.to_s.strip
            return value unless value.empty?
          end

          nil
        end

        def credential_value(credentials, key)
          credentials&.dig(:lemon_squeezy, key) || credentials&.dig("lemon_squeezy", key.to_s)
        rescue NoMethodError
          nil
        end

        def positive_timeout(value, name)
          timeout = Float(value)
          return timeout if timeout.finite? && timeout.positive?

          raise ArgumentError, "Lemon Squeezy #{name} timeout must be positive"
        rescue TypeError, ArgumentError
          raise Errors::ConfigurationError.new(
            "Lemon Squeezy #{name} timeout must be positive"
          ), cause: nil
        end
    end
  end
end
