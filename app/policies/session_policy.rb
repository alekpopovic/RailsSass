class SessionPolicy < ApplicationPolicy
  def index?
    record == Session && authenticated_account_context?
  end

  def destroy?
    authenticated_account_context? &&
      record.is_a?(Session) &&
      record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless authenticated_account_context?

      Current.user.sessions.merge(scope)
    end

    private
      def authenticated_account_context?
        authenticated_context? && Current.user&.id == user&.id
      end
  end

  private
    def authenticated_account_context?
      authenticated_context? && Current.user&.id == user&.id
    end
end
