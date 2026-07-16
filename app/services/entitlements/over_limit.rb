module Entitlements
  class OverLimit < LimitExceeded
    def initialize(usage:)
      super(usage: usage, reason_code: :over_limit)
    end

    def safe_message
      "Current usage is above the plan limit. Reduce usage before adding another resource."
    end
  end
end
