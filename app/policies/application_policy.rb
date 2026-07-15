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
  end
end
