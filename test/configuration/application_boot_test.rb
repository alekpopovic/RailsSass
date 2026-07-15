require "test_helper"

class ApplicationBootTest < ActiveSupport::TestCase
  test "boots and eager loads in the test environment" do
    assert_predicate Rails.env, :test?
    assert_predicate Rails.application, :initialized?
    assert_nothing_raised { Rails.application.eager_load! }
  end
end
