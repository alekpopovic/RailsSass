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
          capacity = decision.capacity
          return if capacity == Access::Decision::UNLIMITED

          usage = Current.organization.analytics_reports.count
          return if usage + decision.capacity_delta <= capacity

          report.errors.add(:base, LIMIT_REACHED_MESSAGE)
          raise ActiveRecord::RecordInvalid, report
        end
    end
  end
end
