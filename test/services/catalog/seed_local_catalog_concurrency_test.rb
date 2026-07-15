require "test_helper"
require "timeout"

class Catalog::SeedLocalCatalogConcurrencyTest < ActiveSupport::TestCase
  PRODUCT_KEYS = %w[analytics core crm].freeze
  PLAN_KEYS = %w[professional starter].freeze

  self.use_transactional_tests = false

  setup do
    @products_before = records_by_key(Product, PRODUCT_KEYS)
    @plans_before = records_by_key(Plan, PLAN_KEYS)
  end

  teardown do
    restore_records(Plan, PLAN_KEYS, @plans_before)
    restore_records(Product, PRODUCT_KEYS, @products_before)
  end

  test "concurrent local seeds converge to one row for every stable key" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << Catalog::SeedLocalCatalog.new.call
        rescue => error
          results << error
        end
      end
    end

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(5) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal [ true, true ], outcomes
    assert_equal PRODUCT_KEYS, Product.where(key: PRODUCT_KEYS).order(:key).pluck(:key)
    assert_equal PLAN_KEYS, Plan.where(key: PLAN_KEYS).order(:key).pluck(:key)
  ensure
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  private
    def records_by_key(model, keys)
      model.where(key: keys).index_by(&:key).transform_values do |record|
        record.attributes.except("created_at", "updated_at")
      end
    end

    def restore_records(model, keys, snapshots)
      model.where(key: keys).where.not(key: snapshots.keys).delete_all
      snapshots.values.sort_by { |attributes| attributes.fetch("free", false) ? 1 : 0 }.each do |attributes|
        model.find(attributes.fetch("id")).update_columns(attributes.except("id", "key"))
      end
    end
end
