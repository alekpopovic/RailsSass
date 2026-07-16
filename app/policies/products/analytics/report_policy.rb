module Products
  module Analytics
    class ReportPolicy < ApplicationPolicy
      def index?
        access_allowed?(:report_read)
      end

      def show?
        owned_record? && access_allowed?(:report_read)
      end

      def create?
        owned_record? && record.new_record? && access_allowed?(:report_create)
      end

      def export?
        owned_record? && record.persisted? && access_allowed?(:export_run)
      end

      def manage?
        owned_record? && record.persisted? && access_allowed?(:report_manage)
      end

      class Scope < ApplicationPolicy::Scope
        def resolve
          tenant_scope = current_organization_scope
          return tenant_scope.none unless ActionRegistry.decision(
            :report_read,
            context: context
          ).allowed?

          tenant_scope.merge(scope)
        end

        private
          def current_organization_scope
            current_organization = Current.organization
            return scope.none unless current_organization&.persisted?

            current_organization.analytics_reports
          end
      end

      private
        def access_allowed?(action)
          ActionRegistry.decision(action, context: context).allowed?
        end

        def owned_record?
          record.is_a?(AnalyticsReport) && record_owned_by_current_organization?
        end
    end
  end
end
