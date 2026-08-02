# Be sure to restart your server when you modify this file.

require "securerandom"

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :none
    policy.connect_src :self
    policy.font_src :self
    policy.form_action :self
    policy.frame_ancestors :none
    policy.img_src :self, :data
    policy.manifest_src :self
    policy.object_src :none
    policy.script_src :self
    policy.style_src :self
    policy.worker_src :self
  end

  # Importmap emits a small inline map/module bootstrap. A fresh request nonce
  # permits only those Rails-generated tags without allowing arbitrary inline
  # JavaScript.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.content_security_policy_nonce_auto = true
  config.content_security_policy_report_only = false
end
