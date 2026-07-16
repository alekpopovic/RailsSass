module Billing
  class ProviderPriceMapping < ApplicationRecord
    PROVIDER_ID_PATTERN = /\A[1-9][0-9]*\z/

    belongs_to :plan_price,
      inverse_of: :billing_provider_price_mappings
    has_many :checkout_attempts,
      class_name: "Billing::CheckoutAttempt",
      foreign_key: [ :plan_price_id, :provider, :environment ],
      primary_key: [ :plan_price_id, :provider, :environment ],
      dependent: :restrict_with_exception,
      inverse_of: :provider_price_mapping

    enum :environment, { test: "test", live: "live" }, prefix: true, validate: true

    normalizes :provider_store_id, :provider_product_id, :provider_variant_id,
      with: ->(value) { value.to_s.strip.presence }

    attr_readonly :plan_price_id,
      :provider,
      :environment,
      :provider_store_id,
      :provider_product_id,
      :provider_variant_id

    validates :provider, inclusion: { in: %w[lemon_squeezy] }
    validates :provider_store_id, :provider_product_id, :provider_variant_id,
      presence: true,
      length: { maximum: 64 },
      format: { with: PROVIDER_ID_PATTERN }
    validates :active, inclusion: { in: [ true, false ] }
    validates :plan_price_id, uniqueness: { scope: %i[provider environment] }
    validate :identifiers_match_plan_price

    def test_mode?
      environment_test?
    end

    def checkout_eligible?
      active? &&
        plan_price.active? &&
        plan_price.plan.active? &&
        !plan_price.plan.free?
    end

    private
      def identifiers_match_plan_price
        return unless plan_price

        expected = [
          plan_price.lemon_store_id,
          plan_price.lemon_product_id,
          plan_price.lemon_variant_id
        ]
        actual = [ provider_store_id, provider_product_id, provider_variant_id ]
        return if expected == actual

        errors.add(:plan_price, "must have the same Lemon provider identifiers")
      end
  end
end
