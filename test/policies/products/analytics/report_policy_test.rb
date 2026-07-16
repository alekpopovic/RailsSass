require "test_helper"

class Products::Analytics::ReportPolicyTest < ActiveSupport::TestCase
  teardown { Current.reset }

  test "record actions and scope fail closed without a current tenant context" do
    context = AuthorizationContext.new(user: nil, organization: nil, membership: nil)
    report = AnalyticsReport.new
    policy = Products::Analytics::ReportPolicy.new(context, report)

    assert_not policy.index?
    assert_not policy.show?
    assert_not policy.create?
    assert_not policy.export?
    assert_not policy.manage?
    assert_empty Products::Analytics::ReportPolicy::Scope
      .new(context, AnalyticsReport.all)
      .resolve
  end
end
