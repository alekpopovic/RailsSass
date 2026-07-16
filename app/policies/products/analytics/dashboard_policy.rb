module Products
  module Analytics
    class DashboardPolicy < ApplicationPolicy
      def show?
        ActionRegistry.decision(:dashboard_read, context: context).allowed?
      end
    end
  end
end
