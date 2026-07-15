require "test_helper"
require "timeout"

class PlanActiveFreeConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @keys = 2.times.map { |index| "concurrent_free_#{index}_#{SecureRandom.hex(6)}" }
    @baseline_key = "concurrent_free_baseline_#{SecureRandom.hex(6)}"
    @baseline = Plan.find_by(active: true, free: true)
    unless @baseline
      Plan.insert_all!([ raw_plan_attributes(@baseline_key) ])
      @baseline = Plan.find_by!(key: @baseline_key)
      @created_baseline = true
    end
  end

  teardown do
    Plan.where(key: @keys).delete_all
    @baseline.delete if @created_baseline
  end

  test "concurrent direct inserts cannot create two active free plans" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = @keys.map do |key|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Plan.insert_all!([ raw_plan_attributes(key) ])
          results << :success
        rescue => error
          results << error
        end
      end
    end

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(5) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_empty outcomes.grep(:success)
    failures = outcomes.grep(ActiveRecord::RecordNotUnique)
    assert_equal 2, failures.size
    failures.each { |failure| assert_kind_of PG::UniqueViolation, failure.cause }
    assert_equal @baseline.id, Plan.find_by!(active: true, free: true).id
    assert_empty Plan.where(key: @keys)
  ensure
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  private
    def raw_plan_attributes(key)
      now = Time.current
      {
        key: key,
        name: "Concurrent Free Plan",
        description: "Synthetic concurrency record.",
        active: true,
        free: true,
        position: 0,
        created_at: now,
        updated_at: now
      }
    end
end
