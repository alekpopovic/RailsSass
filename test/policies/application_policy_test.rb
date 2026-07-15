require "test_helper"

class ApplicationPolicyTest < ActiveSupport::TestCase
  test "denies every base action" do
    policy = ApplicationPolicy.new(Object.new, Object.new)

    %i[index? show? create? new? update? edit? destroy?].each do |query|
      assert_not policy.public_send(query), "expected #{query} to deny access"
    end
  end

  test "requires every policy scope to define resolve" do
    error = assert_raises(NoMethodError) do
      ApplicationPolicy::Scope.new(Object.new, Object.new).resolve
    end

    assert_match "Define #resolve", error.message
  end

  test "application controller includes Pundit authorization" do
    assert_includes ApplicationController.ancestors, Pundit::Authorization
  end

  test "tenant controllers verify record authorization and collection scoping" do
    base_after_actions = after_action_filters(Organizations::BaseController)
    members_after_actions = after_action_filters(Organizations::MembersController)

    assert_includes base_after_actions, :verify_authorized
    assert_includes members_after_actions, :verify_policy_scoped
  end

  test "extracts all tenant authorization inputs from the Pundit context" do
    user = Object.new
    organization = Object.new
    membership = Object.new
    context = AuthorizationContext.new(
      user: user,
      organization: organization,
      membership: membership
    )
    policy = ApplicationPolicy.new(context, Object.new)

    assert_same context, policy.context
    assert_same user, policy.user
    assert_same organization, policy.organization
    assert_same membership, policy.membership
  end

  private
    def after_action_filters(controller)
      controller._process_action_callbacks
        .select { |callback| callback.kind == :after }
        .map(&:filter)
    end
end
