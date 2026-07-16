require "faraday"
require "json"
require "time"
require "timeout"
require "uri"

module Billing
  module LemonSqueezy
    class Client
      CheckoutResult = Data.define(
        :provider_checkout_id,
        :checkout_url,
        :store_id,
        :variant_id,
        :test_mode,
        :expires_at
      )

      BASE_URL = "https://api.lemonsqueezy.com"
      MEDIA_TYPE = "application/vnd.api+json"
      DEFAULT_OPEN_TIMEOUT = 2
      DEFAULT_READ_TIMEOUT = 5
      MAX_RESPONSE_BYTES = 1_048_576
      MAX_RETRY_AFTER_SECONDS = 3_600
      SAFE_PROVIDER_ID = /\A[a-zA-Z0-9_-]{1,128}\z/
      SAFE_PATH = /\A\/v1\/[a-zA-Z0-9_.\/-]+\z/
      NUMERIC_PROVIDER_ID = /\A[1-9][0-9]*\z/
      CHECKOUT_PATH = %r{\A/checkout/custom/[a-zA-Z0-9_-]+\z}
      CHECKOUT_HOST = /\A[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\z/
      MAX_CHECKOUT_TOKEN_BYTES = 2_048
      MAX_EMAIL_BYTES = 254

      attr_reader :store_id, :environment, :checkout_host, :open_timeout, :read_timeout

      def initialize(
        api_key: nil,
        store_id: nil,
        environment: nil,
        checkout_host: nil,
        open_timeout: DEFAULT_OPEN_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT,
        env: ENV,
        credentials: Rails.application.credentials
      )
        @api_key = configuration_value(api_key, env["LEMON_SQUEEZY_API_KEY"], credential_value(credentials, :api_key))
        @store_id = configuration_value(
          store_id,
          env["LEMON_SQUEEZY_STORE_ID"],
          credential_value(credentials, :store_id),
          default_store_id
        )
        @environment = configuration_value(
          environment,
          env["LEMON_SQUEEZY_ENVIRONMENT"],
          credential_value(credentials, :environment),
          default_environment
        )
        @checkout_host = configuration_value(
          checkout_host,
          env["LEMON_SQUEEZY_CHECKOUT_HOST"],
          credential_value(credentials, :checkout_host)
        )&.downcase
        @open_timeout = positive_timeout(open_timeout, "connect")
        @read_timeout = positive_timeout(read_timeout, "read")

        raise Errors::ConfigurationError, "Lemon Squeezy API key is not configured" unless @api_key
        raise Errors::ConfigurationError, "Lemon Squeezy store ID is not configured" unless @store_id
        unless @environment.in?(%w[test live])
          raise Errors::ConfigurationError, "Lemon Squeezy environment is invalid"
        end
        if @checkout_host && !valid_checkout_host?(@checkout_host)
          raise Errors::ConfigurationError, "Lemon Squeezy checkout host is invalid"
        end
      end

      def test_mode?
        environment == "test"
      end

      def create_checkout(
        variant_id:,
        return_url:,
        expires_at:,
        checkout_attempt_token:,
        email_address: nil
      )
        ensure_checkout_configuration!
        normalized_variant_id = numeric_provider_id!(variant_id, "variant")
        normalized_store_id = numeric_provider_id!(store_id, "store")
        normalized_return_url = safe_return_url!(return_url)
        normalized_expiry = future_time!(expires_at)
        normalized_token = checkout_token!(checkout_attempt_token)
        normalized_email = checkout_email!(email_address)

        response = request(
          method: :post,
          path: "/v1/checkouts",
          body: checkout_request_body(
            store_id: normalized_store_id,
            variant_id: normalized_variant_id,
            return_url: normalized_return_url,
            expires_at: normalized_expiry,
            checkout_attempt_token: normalized_token,
            email_address: normalized_email
          )
        )

        checkout_result(
          response,
          store_id: normalized_store_id,
          variant_id: normalized_variant_id,
          expires_at: normalized_expiry
        )
      end

      def retrieve_subscription(provider_subscription_id:)
        provider_subscription_id = provider_subscription_id.to_s
        unless SAFE_PROVIDER_ID.match?(provider_subscription_id)
          raise Errors::RequestError, "Invalid Lemon Squeezy subscription ID"
        end

        request(method: :get, path: "/v1/subscriptions/#{provider_subscription_id}")
      end

      def retrieve_subscription_snapshot(provider_subscription_id:)
        provider_subscription_id = provider_subscription_id.to_s
        payload = retrieve_subscription(provider_subscription_id: provider_subscription_id)

        SubscriptionSnapshot.parse(
          payload:,
          expected_subscription_id: provider_subscription_id,
          expected_store_id: store_id,
          expected_test_mode: test_mode?
        )
      end

      def inspect
        "#<#{self.class.name} configured=true>"
      end

      private
        def checkout_request_body(
          store_id:,
          variant_id:,
          return_url:,
          expires_at:,
          checkout_attempt_token:,
          email_address:
        )
          checkout_data = {
            custom: { checkout_attempt_token: checkout_attempt_token }
          }
          checkout_data[:email] = email_address if email_address

          {
            data: {
              type: "checkouts",
              attributes: {
                product_options: {
                  redirect_url: return_url,
                  enabled_variants: [ variant_id.to_i ]
                },
                checkout_data: checkout_data,
                expires_at: expires_at.iso8601(6),
                test_mode: test_mode?
              },
              relationships: {
                store: { data: { type: "stores", id: store_id } },
                variant: { data: { type: "variants", id: variant_id } }
              }
            }
          }
        end

        def checkout_result(response, store_id:, variant_id:, expires_at:)
          invalid_checkout_response! unless response.is_a?(Hash)

          data = response["data"]
          invalid_checkout_response! unless data.is_a?(Hash) && data["type"] == "checkouts"

          provider_checkout_id = data["id"].to_s
          invalid_checkout_response! unless SAFE_PROVIDER_ID.match?(provider_checkout_id)

          attributes = data["attributes"]
          invalid_checkout_response! unless attributes.is_a?(Hash)
          invalid_checkout_response! unless attributes["store_id"].to_s == store_id
          invalid_checkout_response! unless attributes["variant_id"].to_s == variant_id
          invalid_checkout_response! unless attributes["test_mode"] == test_mode?
          invalid_checkout_response! unless attributes.key?("custom_price") && attributes["custom_price"].nil?

          validate_enabled_variants!(attributes, variant_id)
          returned_expiry = strict_iso8601_time(attributes["expires_at"])
          invalid_checkout_response! unless (returned_expiry - expires_at).abs <= 1.second

          checkout_url = safe_checkout_url!(attributes["url"])
          CheckoutResult.new(
            provider_checkout_id: provider_checkout_id,
            checkout_url: checkout_url,
            store_id: store_id,
            variant_id: variant_id,
            test_mode: test_mode?,
            expires_at: returned_expiry
          )
        end

        def validate_enabled_variants!(attributes, variant_id)
          product_options = attributes["product_options"]
          invalid_checkout_response! unless product_options.is_a?(Hash)

          enabled_variants = product_options["enabled_variants"]
          invalid_checkout_response! unless enabled_variants.is_a?(Array)

          returned_ids = enabled_variants.map(&:to_s)
          invalid_checkout_response! unless returned_ids == [ variant_id ]
        end

        def ensure_checkout_configuration!
          return if checkout_host

          raise Errors::ConfigurationError, "Lemon Squeezy checkout host is not configured"
        end

        def numeric_provider_id!(value, label)
          normalized = value.to_s
          return normalized if NUMERIC_PROVIDER_ID.match?(normalized)

          raise Errors::RequestError, "Invalid Lemon Squeezy #{label} ID"
        end

        def safe_return_url!(value)
          normalized = value.to_s
          uri = URI.parse(normalized)
          allowed_scheme = uri.is_a?(URI::HTTPS) || (!Rails.env.production? && uri.is_a?(URI::HTTP))
          valid = allowed_scheme &&
            uri.host.present? &&
            uri.userinfo.nil? &&
            uri.fragment.nil? &&
            !control_characters?(normalized)
          return normalized if valid

          raise Errors::RequestError, "Invalid checkout return URL"
        rescue URI::InvalidURIError
          raise Errors::RequestError.new("Invalid checkout return URL"), cause: nil
        end

        def future_time!(value)
          parsed = value.to_time
          return parsed if parsed > Time.current

          raise Errors::RequestError, "Invalid checkout expiry"
        rescue NoMethodError, TypeError, ArgumentError
          raise Errors::RequestError.new("Invalid checkout expiry"), cause: nil
        end

        def checkout_token!(value)
          token = value.to_s
          valid = token.present? &&
            token.bytesize <= MAX_CHECKOUT_TOKEN_BYTES &&
            !control_characters?(token)
          return token if valid

          raise Errors::RequestError, "Invalid checkout token"
        end

        def checkout_email!(value)
          return if value.nil?

          email = value.to_s.strip.downcase
          return email if email.present? && email.bytesize <= MAX_EMAIL_BYTES && !control_characters?(email)

          raise Errors::RequestError, "Invalid checkout email"
        end

        def safe_checkout_url!(value)
          normalized = value.to_s
          uri = URI.parse(normalized)
          valid = uri.is_a?(URI::HTTPS) &&
            uri.host&.downcase == checkout_host &&
            uri.port == 443 &&
            uri.userinfo.nil? &&
            uri.fragment.nil? &&
            uri.query.present? &&
            CHECKOUT_PATH.match?(uri.path) &&
            !control_characters?(normalized)
          return normalized if valid

          invalid_checkout_response!
        rescue URI::InvalidURIError
          invalid_checkout_response!
        end

        def strict_iso8601_time(value)
          return invalid_checkout_response! unless value.is_a?(String)

          Time.iso8601(value)
        rescue ArgumentError
          invalid_checkout_response!
        end

        def invalid_checkout_response!
          raise Errors::InvalidResponseError.new(
            "Lemon Squeezy returned an invalid checkout response",
            status: 200
          ), cause: nil
        end

        def valid_checkout_host?(value)
          CHECKOUT_HOST.match?(value) &&
            value.include?(".") &&
            !value.include?("..")
        end

        def control_characters?(value)
          value.match?(/[[:cntrl:]]/)
        end

        def default_environment
          Rails.configuration.x.billing.lemon_squeezy.environment
        end

        def default_store_id
          Rails.configuration.x.billing.lemon_squeezy.store_id
        end

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
