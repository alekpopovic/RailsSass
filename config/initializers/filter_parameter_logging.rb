# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :token_digest, :session_token,
  :reset_token, :verification_token, :_key, :crypt, :salt, :certificate,
  :otp, :ssn, :cvv, :cvc, :authorization, :api_key, :signature,
  :raw_payload, :settings, :checkout_url, :portal_url
]
