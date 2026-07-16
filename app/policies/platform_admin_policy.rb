class PlatformAdminPolicy < ApplicationPolicy
  def access?
    platform_admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      platform_admin? ? scope.all : scope.none
    end

    private
      def platform_admin?
        PlatformAdminPolicy.platform_admin?(context:, user:)
      end
  end

  class << self
    def platform_admin?(context:, user:)
      return false unless context.respond_to?(:authenticated?) && context.authenticated?
      return false unless user&.persisted?

      User.where(
        id: user.id,
        system_role: User.system_roles.fetch(:platform_admin),
        disabled_at: nil
      ).where.not(email_verified_at: nil).exists?
    end
  end

  private
    def platform_admin?
      self.class.platform_admin?(context:, user:)
    end
end
