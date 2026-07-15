require "test_helper"
require "timeout"
require_relative "../../../support/organization_test_helper"

class Organizations::Memberships::ConcurrencyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @first_owner = create_test_user(email_address: "first-owner-#{suffix}@example.test")
    @second_owner = create_test_user(email_address: "second-owner-#{suffix}@example.test")
    @organization, @first_membership = create_test_organization_with_owner(
      owner: @first_owner,
      name: "Concurrent Organization",
      slug: "concurrent-#{suffix}"
    )
    @second_membership = create_test_membership(
      organization: @organization,
      user: @second_owner,
      role: :owner
    )
    @first_session, = Session.issue_for!(@first_owner, ip_address: nil, user_agent: "Concurrency test")
    @second_session, = Session.issue_for!(@second_owner, ip_address: nil, user_agent: "Concurrency test")
  end

  teardown do
    Current.reset
    Session.where(id: [ @first_session&.id, @second_session&.id ].compact).delete_all
    if @organization
      Current.organization = @organization
      Organization.transaction do
        Current.organization.organization_memberships
          .where(organization_id: Current.organization.id)
          .delete_all
        Current.organization.delete
      end
    end
    User.where(id: [ @first_owner&.id, @second_owner&.id ].compact).delete_all
  ensure
    Current.reset
  end

  test "concurrent service demotion and removal cannot eliminate both active owners" do
    first_locked = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    results = Queue.new
    threads = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless Thread.current[:membership_transition_worker] == :first
      next unless organization_lock_query?(payload[:sql])

      first_locked << true
      release_first.pop
    end

    threads << service_transition_thread(
      worker: :first,
      user_id: @first_owner.id,
      session_id: @first_session.id,
      membership_id: @first_membership.id,
      operation: :change_role,
      results: results
    )
    Timeout.timeout(5) { first_locked.pop }

    threads << service_transition_thread(
      worker: :second,
      user_id: @second_owner.id,
      session_id: @second_session.id,
      membership_id: @second_membership.id,
      operation: :remove,
      started: second_started,
      results: results
    )
    backend_pid = Timeout.timeout(5) { second_started.pop }
    activity = wait_for_organization_lock!(backend_pid)

    assert_equal "Lock", activity.fetch("wait_event_type")
    assert organization_lock_query?(activity.fetch("query"))

    release_first << true
    Timeout.timeout(5) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal 1, outcomes.count(:success)
    failure = outcomes.grep(ActiveRecord::RecordInvalid).sole
    assert_includes failure.record.errors[:base], OrganizationMembership::LAST_ACTIVE_OWNER_MESSAGE
    assert_equal 1, @organization.organization_memberships.active_owners.count
  ensure
    release_first&.push(true) if threads&.any?(&:alive?)
    finish_threads(threads)
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "database serializes concurrent direct transitions at the active owner constraint" do
    ready = Queue.new
    start = Queue.new
    updated = Queue.new
    check_constraint = Queue.new
    results = Queue.new
    operations = [
      [ @first_membership.id, { role: "member" } ],
      [ @second_membership.id, { status: "suspended" } ]
    ]

    threads = operations.map do |membership_id, transition|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Current.organization = Organization.find(@organization.id)

          OrganizationMembership.transaction do
            Current.organization.organization_memberships
              .where(id: membership_id)
              .update_all(transition.merge(updated_at: Time.current))
            updated << true
            check_constraint.pop
            OrganizationMembership.connection.execute(
              "SET CONSTRAINTS organization_must_have_active_owner IMMEDIATE"
            )
          end

          results << :success
        rescue => error
          results << error
        ensure
          Current.reset
        end
      end
    end

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(5) { 2.times { updated.pop } }
    2.times { check_constraint << true }
    Timeout.timeout(5) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal 1, outcomes.count(:success)
    failure = outcomes.grep(ActiveRecord::StatementInvalid).sole
    assert_kind_of PG::CheckViolation, failure.cause
    assert_equal 1, @organization.organization_memberships.active_owners.count
  ensure
    2.times { check_constraint&.push(true) }
    finish_threads(threads)
  end

  private
    def finish_threads(threads)
      threads&.each do |thread|
        next if thread.join(1)

        thread.kill
        thread.join
      end
    end

    def service_transition_thread(
      worker:,
      user_id:,
      session_id:,
      membership_id:,
      operation:,
      results:,
      started: nil
    )
      Thread.new do
        Thread.current[:membership_transition_worker] = worker

        ActiveRecord::Base.connection_pool.with_connection do |connection|
          establish_thread_context(user_id: user_id, session_id: session_id)
          started&.push(connection.raw_connection.backend_pid)

          if operation == :change_role
            Organizations::Memberships::ChangeRole.new(
              actor: Current.user,
              membership_id: membership_id,
              role: :member
            ).call
          else
            Organizations::Memberships::Remove.new(
              actor: Current.user,
              membership_id: membership_id
            ).call
          end

          results << :success
        rescue => error
          results << error
        ensure
          Current.reset
          Thread.current[:membership_transition_worker] = nil
        end
      end
    end

    def wait_for_organization_lock!(backend_pid)
      Timeout.timeout(5) do
        loop do
          activity = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
            SELECT wait_event_type, query
            FROM pg_stat_activity
            WHERE pid = #{Integer(backend_pid)}
          SQL
          return activity if activity&.fetch("wait_event_type") == "Lock" &&
            organization_lock_query?(activity.fetch("query"))

          sleep 0.01
        end
      end
    end

    def organization_lock_query?(sql)
      sql.include?('FROM "organizations"') && sql.include?("FOR UPDATE")
    end

    def establish_thread_context(user_id:, session_id:)
      Current.session = Session.includes(:user).find(session_id)
      Current.organization = Organization.find(@organization.id)
      Current.organization_membership = Current.organization
        .organization_memberships
        .find_by!(user_id: user_id)
    end
end
