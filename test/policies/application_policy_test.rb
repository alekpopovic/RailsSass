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
end
