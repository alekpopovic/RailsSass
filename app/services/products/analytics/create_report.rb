module Products
  module Analytics
    class CreateReport
      LIMIT_REACHED_MESSAGE = "The current plan's report limit has been reached."
      ALLOWED_ATTRIBUTES = %i[name description].freeze

      def initialize(context:, attributes:)
        @context = context
        @attributes = attributes.to_h.symbolize_keys.slice(*ALLOWED_ATTRIBUTES)
      end

      def call
        organization = Current.organization
        raise ActiveRecord::RecordNotFound unless organization&.persisted?

        organization.with_lock do
          raise ActiveRecord::RecordNotFound unless Current.organization&.id == organization.id

          decision = ActionRegistry.decision(:report_create, context: context)
          unless decision.allowed?
            raise Pundit::NotAuthorizedError, "analytics report creation is not allowed"
          end

          report = Current.organization.analytics_reports.new(attributes)
          enforce_capacity!(report, decision)
          report.save!
          report
        end
      end

      private
        attr_reader :context, :attributes

        def enforce_capacity!(report, decision)
          Entitlements::LimitEnforcer.new(
            organization: Current.organization,
            product_key: ActionRegistry::PRODUCT_KEY,
            feature_key: decision.action.capacity_feature_key,
            capacity: decision.capacity
          ).enforce!(delta: decision.capacity_delta)
        rescue Entitlements::LimitExceeded
          report.errors.add(:base, LIMIT_REACHED_MESSAGE)
          raise ActiveRecord::RecordInvalid, report
        end
    end
  end
end
