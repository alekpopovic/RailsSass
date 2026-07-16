class UserPolicy < ApplicationPolicy
  def show?
    authenticated_self?
  end

  alias_method :update?, :show?

  private
    def authenticated_self?
      record.is_a?(User) &&
        record.persisted? &&
        user&.id == record.id &&
        Current.user&.id == record.id &&
        context.respond_to?(:authenticated?) &&
        context.authenticated?
    end
end
