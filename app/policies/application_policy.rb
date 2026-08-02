class ApplicationPolicy
  attr_reader :context, :user, :organization, :membership, :record

  def initialize(context, record)
    @context = context
    @user = context.respond_to?(:user) ? context.user : context
    @organization = context.organization if context.respond_to?(:organization)
    @membership = context.membership if context.respond_to?(:membership)
    @record = record
  end

  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def new?
    create?
  end

  def update?
    false
  end

  def edit?
    update?
  end

  def destroy?
    false
  end

  protected
    def authenticated_context?
      context.respond_to?(:authenticated?) && context.authenticated?
    end

    def product_access_decision(product_key:, permission_key:, feature_key: nil, now: Time.current)
      Access::Gate.new(
        context: context,
        product_key: product_key,
        permission_key: permission_key,
        feature_key: feature_key,
        now: now
      ).call
    end

    def product_access_allowed?(**attributes)
      product_access_decision(**attributes).allowed?
    end

    def record_owned_by_current_organization?
      organization&.persisted? &&
        Current.organization&.id == organization.id &&
        record&.respond_to?(:organization_id) &&
        record.organization_id == organization.id
    end

  class Scope
    attr_reader :context, :user, :organization, :membership, :scope

    def initialize(context, scope)
      @context = context
      @user = context.respond_to?(:user) ? context.user : context
      @organization = context.organization if context.respond_to?(:organization)
      @membership = context.membership if context.respond_to?(:membership)
      @scope = scope
    end

    def resolve
      raise NoMethodError, "Define #resolve in #{self.class}"
    end

    protected
      def authenticated_context?
        context.respond_to?(:authenticated?) && context.authenticated?
      end

      def product_access_decision(product_key:, permission_key:, feature_key: nil, now: Time.current)
        Access::Gate.new(
          context: context,
          product_key: product_key,
          permission_key: permission_key,
          feature_key: feature_key,
          now: now
        ).call
      end

      def product_access_allowed?(**attributes)
        product_access_decision(**attributes).allowed?
      end
  end
end
