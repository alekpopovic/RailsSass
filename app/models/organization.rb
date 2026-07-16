class Organization < ApplicationRecord
  NAME_MAX_LENGTH = 100
  SLUG_MAX_LENGTH = 63
  SLUG_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  has_many :organization_memberships, dependent: :restrict_with_exception, inverse_of: :organization
  has_many :organization_access_locators,
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :organization_invitations,
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :audit_events,
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :analytics_reports,
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :billing_customers,
    class_name: "Billing::Customer",
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :billing_checkout_attempts,
    class_name: "Billing::CheckoutAttempt",
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :billing_provider_locators,
    class_name: "Billing::ProviderLocator",
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :billing_subscriptions,
    class_name: "Billing::Subscription",
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :billing_plan_changes,
    class_name: "Billing::PlanChange",
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :billing_webhook_events,
    class_name: "Billing::WebhookEvent",
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :product_roles,
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :product_memberships,
    dependent: :restrict_with_exception,
    inverse_of: :organization
  has_many :product_membership_roles,
    dependent: :restrict_with_exception,
    inverse_of: :organization
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

  def effective_plan(now: Time.current)
    Entitlements::Resolver.new(organization: self, now: now).effective_plan
  end
end
