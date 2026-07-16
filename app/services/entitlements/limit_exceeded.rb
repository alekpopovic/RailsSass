module Entitlements
  class LimitExceeded < StandardError
    attr_reader :usage, :reason_code

    def initialize(usage:, reason_code: :limit_exceeded)
      @usage = usage
      @reason_code = reason_code.to_sym
      super(safe_message)
    end

    def safe_message
      "The current plan limit has been reached."
    end

    def remediation_items
      usage.remediation_items
    end
  end
end
