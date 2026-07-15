class OrganizationAccessLocator < ApplicationRecord
  belongs_to :organization_membership,
    inverse_of: :organization_access_locator,
    optional: true
  belongs_to :user, inverse_of: :organization_access_locators
  belongs_to :organization, inverse_of: :organization_access_locators

  attr_readonly :organization_membership_id, :user_id, :organization_id

  validates :organization_membership_id, presence: true, uniqueness: true
  validates :user_id, uniqueness: { scope: :organization_id }
  validate :active_membership_matches_identity

  private
    def active_membership_matches_identity
      membership = association(:organization_membership).target
      return unless membership

      errors.add(:organization_membership, "must be active") unless membership.active?

      return if membership.user_id == user_id && membership.organization_id == organization_id

      errors.add(:organization_membership, "must match the user and organization")
    end
end
