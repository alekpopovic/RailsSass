class Organization < ApplicationRecord
  NAME_MAX_LENGTH = 100
  SLUG_MAX_LENGTH = 63
  SLUG_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  has_many :organization_memberships, dependent: :restrict_with_exception, inverse_of: :organization
  has_many :users, through: :organization_memberships

  enum :status, { active: "active", suspended: "suspended" },
    default: :active,
    validate: true

  normalizes :name, with: ->(name) { name.strip }
  normalizes :slug, with: ->(slug) do
    slug.to_s.parameterize(separator: "-").tr("_", "-").squeeze("-")
  end

  attr_readonly :public_id, :slug

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :slug,
    presence: true,
    length: { maximum: SLUG_MAX_LENGTH },
    format: { with: SLUG_PATTERN },
    uniqueness: true
end
