module Billing
  class Customer < ApplicationRecord
    PROVIDER_CUSTOMER_ID_PATTERN = /\A\S+\z/

    belongs_to :organization, inverse_of: :billing_customers
    has_many :subscriptions,
      class_name: "Billing::Subscription",
      foreign_key: :billing_customer_id,
      dependent: :restrict_with_exception,
      inverse_of: :billing_customer

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true

    normalizes :provider_customer_id, with: ->(identifier) { identifier.to_s.strip }

    attr_readonly :organization_id, :provider, :environment, :provider_customer_id, :test_mode

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :provider_customer_id,
      presence: true,
      length: { maximum: 128 },
      format: { with: PROVIDER_CUSTOMER_ID_PATTERN }
    validates :test_mode, inclusion: { in: [ true, false ] }
    validate :test_mode_matches_environment

    private
      def test_mode_matches_environment
        return if environment.blank? || test_mode.nil?
        return if (environment_test? && test_mode) || (environment_live? && !test_mode)

        errors.add(:test_mode, "must match the provider environment")
      end
  end
end
