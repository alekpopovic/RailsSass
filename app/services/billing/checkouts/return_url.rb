require "uri"

module Billing
  module Checkouts
    class ReturnUrl
      class << self
        def call(organization:, url_options: default_url_options)
          options = normalized_options(url_options)
          expected_path = routes.organization_billing_checkout_pending_path(
            organization_slug: organization.slug
          )
          url = routes.organization_billing_checkout_pending_url(
            organization_slug: organization.slug,
            **options
          )
          uri = URI.parse(url)

          valid = uri.host == options.fetch(:host) &&
            uri.path == expected_path &&
            uri.query.nil? &&
            uri.fragment.nil? &&
            uri.userinfo.nil? &&
            allowed_scheme?(uri)
          return url if valid

          raise_configuration_error
        rescue KeyError, URI::InvalidURIError
          raise_configuration_error
        end

        private
          def routes
            Rails.application.routes.url_helpers
          end

          def default_url_options
            Rails.application.config.action_mailer.default_url_options
          end

          def normalized_options(value)
            options = value.to_h.symbolize_keys.slice(:host, :port, :protocol)
            options[:host] = options[:host].to_s.strip.downcase
            options[:protocol] = options.fetch(:protocol, Rails.env.production? ? "https" : "http").to_s
            raise_configuration_error if options[:host].blank?

            options
          end

          def allowed_scheme?(uri)
            uri.is_a?(URI::HTTPS) || (!Rails.env.production? && uri.is_a?(URI::HTTP))
          end

          def raise_configuration_error
            raise Billing::LemonSqueezy::Errors::ConfigurationError,
              "Application checkout return URL is not configured safely"
          end
      end
    end
  end
end
