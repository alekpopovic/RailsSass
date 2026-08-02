require "test_helper"
require "timeout"

class Accounts::TokenMutationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  OLD_PASSWORD = "old-password-for-concurrency"
  FIRST_NEW_PASSWORD = "first-new-password-for-concurrency"
  SECOND_NEW_PASSWORD = "second-new-password-for-concurrency"

  setup do
    suffix = SecureRandom.hex(6)
    @password_user = create_user(
      email_address: "password-concurrency-#{suffix}@example.test",
      verified: true
    )
    @verification_user = create_user(
      email_address: "verification-concurrency-#{suffix}@example.test",
      verified: false
    )
  end

  teardown do
    Session.where(user_id: [ @password_user&.id, @verification_user&.id ].compact).delete_all
    User.where(id: [ @password_user&.id, @verification_user&.id ].compact).delete_all
  end

  test "a password reset token has only one effect under concurrent use" do
    2.times do
      Session.issue_for!(
        @password_user,
        ip_address: "127.0.0.1",
        user_agent: "Password concurrency test"
      )
    end
    token = @password_user.password_reset_token
    passwords = [ FIRST_NEW_PASSWORD, SECOND_NEW_PASSWORD ]

    outcomes = run_after_synchronized_initial_lookup do |index|
      Accounts::ResetPassword.new(
        raw_token: token,
        attributes: {
          password: passwords.fetch(index),
          password_confirmation: passwords.fetch(index)
        }
      ).call
    end

    assert_equal 1, outcomes.count(&:updated?)
    assert_equal 1, outcomes.count(&:invalid_token?)
    assert passwords.any? { |password| @password_user.reload.authenticate(password) }
    assert_empty @password_user.sessions.reload
    assert_nil User.find_by_password_reset_token(token)
  end

  test "an email verification token has only one effect under concurrent use" do
    token = @verification_user.email_verification_token

    outcomes = run_after_synchronized_initial_lookup do
      Accounts::VerifyEmail.new(raw_token: token).call
    end

    assert_equal 1, outcomes.count(&:verified?)
    assert_equal 1, outcomes.count(&:invalid_token?)
    assert_predicate @verification_user.reload, :email_verified?
    assert_nil User.find_by_email_verification_token(token)
  end

  test "password reset cannot be followed by session issuance from an in-flight old-password login" do
    token = @password_user.password_reset_token
    authenticated = Queue.new
    release_authentication = Queue.new
    result = Queue.new
    original_authenticate_by = User.method(:authenticate_by)

    User.define_singleton_method(:authenticate_by) do |**attributes|
      candidate = original_authenticate_by.call(**attributes)
      if Thread.current[:password_reset_login_race]
        authenticated << true
        release_authentication.pop
      end
      candidate
    end

    login_thread = Thread.new do
      Thread.current[:password_reset_login_race] = true
      ActiveRecord::Base.connection_pool.with_connection do
        result << Accounts::Authenticate.new(
          email_address: @password_user.email_address,
          password: OLD_PASSWORD,
          ip_address: "127.0.0.1",
          user_agent: "Password reset race test"
        ).call
      end
    rescue => error
      result << error
    end

    Timeout.timeout(10) { authenticated.pop }
    reset_result = Accounts::ResetPassword.new(
      raw_token: token,
      attributes: {
        password: FIRST_NEW_PASSWORD,
        password_confirmation: FIRST_NEW_PASSWORD
      }
    ).call
    release_authentication << true
    Timeout.timeout(10) { login_thread.join }
    login_result = result.pop

    assert_predicate reset_result, :updated?
    assert_instance_of Accounts::Authenticate::Result, login_result
    assert_not_predicate login_result, :authenticated?
    assert_empty @password_user.sessions.reload
    assert_not @password_user.reload.authenticate(OLD_PASSWORD)
    assert @password_user.authenticate(FIRST_NEW_PASSWORD)
  ensure
    release_authentication << true if release_authentication&.empty?
    login_thread&.join(1)
    User.define_singleton_method(:authenticate_by, original_authenticate_by) if original_authenticate_by
  end

  private
    def create_user(email_address:, verified:)
      User.create!(
        name: "Token Concurrency User",
        email_address: email_address,
        password: OLD_PASSWORD,
        password_confirmation: OLD_PASSWORD,
        email_verified_at: verified ? Time.current : nil
      )
    end

    def run_after_synchronized_initial_lookup(&operation)
      initial_reads = Queue.new
      releases = Queue.new
      results = Queue.new
      counter_lock = Mutex.new
      lookup_count = 0
      threads = nil
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        next unless sql.include?('FROM "users"') && !sql.include?("FOR UPDATE")

        initial_lookup = counter_lock.synchronize do
          lookup_count += 1
          lookup_count <= 2
        end
        if initial_lookup
          initial_reads << true
          releases.pop
        end
      end

      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            results << operation.call(index)
          rescue => error
            results << error
          end
        end
      end

      Timeout.timeout(5) { 2.times { initial_reads.pop } }
      2.times { releases << true }
      Timeout.timeout(10) { threads.each(&:join) }

      2.times.map { results.pop }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      threads&.each do |thread|
        next if thread.join(1)

        thread.kill
        thread.join
      end
    end
end
