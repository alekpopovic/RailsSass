require "test_helper"
require "rake"
require_relative "../support/authentication_test_helper"

Rails.application.load_tasks unless Rake::Task.task_defined?("platform_admin:promote")

class PlatformAdminTaskTest < ActiveSupport::TestCase
  include AuthenticationTestHelper

  setup do
    @task = Rake::Task["platform_admin:promote"]
  end

  teardown do
    @task.reenable
  end

  test "promotes a verified enabled user by normalized email and changes no account identity" do
    user = create_test_user(email_address: "platform-task@example.test")
    original_attributes = user.attributes.slice(
      "name",
      "email_address",
      "password_digest",
      "email_verified_at",
      "disabled_at"
    )

    stdout, stderr = capture_io { invoke_task("  PLATFORM-TASK@EXAMPLE.TEST  ") }

    assert_equal "Platform administrator access granted.\n", stdout
    assert_empty stderr
    assert_predicate user.reload, :platform_admin?
    assert_equal original_attributes, user.attributes.slice(*original_attributes.keys)
  end

  test "is idempotent for an existing platform administrator" do
    user = create_test_user(email_address: "platform-task-idempotent@example.test")
    user.update!(system_role: :platform_admin)
    original_updated_at = user.updated_at

    capture_io { invoke_task(user.email_address) }

    assert_equal original_updated_at, user.reload.updated_at
    assert_predicate user, :platform_admin?
  end

  test "rejects a missing or blank email" do
    [ nil, "   " ].each do |email_address|
      _stdout, stderr = capture_io do
        error = assert_raises(SystemExit) { invoke_task(email_address) }
        assert_equal 1, error.status
      end

      assert_equal "Email is required.\n", stderr
    end
  end

  test "rejects an unknown user" do
    _stdout, stderr = capture_io do
      error = assert_raises(SystemExit) { invoke_task("missing@example.test") }
      assert_equal 1, error.status
    end

    assert_equal "User was not found.\n", stderr
  end

  test "rejects an unverified user" do
    user = create_test_user(email_address: "platform-task-unverified@example.test", verified: false)

    _stdout, stderr = capture_io do
      error = assert_raises(SystemExit) { invoke_task(user.email_address) }
      assert_equal 1, error.status
    end

    assert_equal "User email must be verified.\n", stderr
    assert_predicate user.reload, :user?
  end

  test "rejects a disabled user" do
    user = create_test_user(
      email_address: "platform-task-disabled@example.test",
      disabled_at: Time.current
    )

    _stdout, stderr = capture_io do
      error = assert_raises(SystemExit) { invoke_task(user.email_address) }
      assert_equal 1, error.status
    end

    assert_equal "Disabled users cannot be platform administrators.\n", stderr
    assert_predicate user.reload, :user?
  end

  private
    def invoke_task(email_address)
      @task.reenable
      @task.invoke(email_address)
    end
end
