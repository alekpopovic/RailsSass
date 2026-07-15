class Current < ActiveSupport::CurrentAttributes
  attribute :session, :organization, :organization_membership
  delegate :user, to: :session, allow_nil: true
end
