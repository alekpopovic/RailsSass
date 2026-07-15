class Current < ActiveSupport::CurrentAttributes
  attribute :session, :organization, :membership
  delegate :user, to: :session, allow_nil: true

  class << self
    # Keep the original name available while tenant-facing code adopts the
    # shorter, canonical membership context requested by the authorization API.
    def organization_membership
      membership
    end

    def organization_membership=(value)
      self.membership = value
    end
  end

  def organization_membership
    membership
  end

  def organization_membership=(value)
    self.membership = value
  end
end
