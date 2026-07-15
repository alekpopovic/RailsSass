class OrganizationMembership < ApplicationRecord
  LAST_ACTIVE_OWNER_MESSAGE = "cannot be changed because the organization needs an active owner"

  belongs_to :organization, inverse_of: :organization_memberships
  belongs_to :user, inverse_of: :organization_memberships
  has_one :organization_access_locator,
    dependent: :restrict_with_exception,
    inverse_of: :organization_membership

  enum :role, {
    owner: "owner",
    admin: "admin",
    billing: "billing",
    member: "member"
  }, validate: true
  enum :status, { active: "active", suspended: "suspended" },
    default: :active,
    validate: true

  scope :active_owners, -> { where(role: "owner", status: "active") }
  scope :eligible_owners, -> { active_owners.joins(:user).where(users: { disabled_at: nil }) }

  attr_readonly :organization_id, :user_id, :role, :status, :joined_at

  validates :joined_at, presence: true
end
