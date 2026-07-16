require "test_helper"
require "timeout"

class Access::SeedSystemProductRbacConcurrencyTest < ActiveSupport::TestCase
  ROLE_KEYS = %w[contributor product_admin viewer].freeze
  PERMISSION_KEYS = %w[
    analytics.dashboard.read
    analytics.export.run
    analytics.report.create
    analytics.report.manage
    analytics.report.read
    contacts.manage
    contacts.view
    settings.manage
  ].freeze

  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @products = [ "analytics", "crm" ].map do |name|
      Product.create!(
        key: "rbac_seed_#{name}_#{suffix}",
        name: "RBAC Seed #{name.capitalize} #{suffix}",
        description: "Isolated product for the concurrent RBAC seed test.",
        active: true
      )
    end
    definitions = Access::SeedSystemProductRbac::CATALOG.values
    catalog = @products.each_with_index.to_h do |product, index|
      [ product.key, definitions.fetch(index) ]
    end
    @seed_class = Class.new(Access::SeedSystemProductRbac) do
      define_method(:catalog) { catalog }
      private :catalog
    end
  end

  teardown do
    remove_seed_records
    Product.where(id: @products.map(&:id)).delete_all
  end

  test "concurrent local seeds converge to one reviewed RBAC graph" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << @seed_class.new.call
        rescue => error
          results << error
        end
      end
    end

    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(10) { threads.each(&:join) }
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }

    assert_equal [ true, true ], outcomes
    assert_equal 6, seeded_roles.count
    assert_equal 8, seeded_permissions.count
    assert_equal 17, seeded_role_permissions.count
    assert_equal 6, seeded_roles.distinct.count(:id)
    assert_equal 8, seeded_permissions.distinct.count(:id)
    assert_equal 17, seeded_role_permissions.distinct.count(:id)
  ensure
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  private
    def products
      Product.where(id: @products.map(&:id))
    end

    def seeded_roles
      ProductRole.where(product: products, organization: nil, key: ROLE_KEYS)
    end

    def seeded_permissions
      ProductPermission.where(product: products, key: PERMISSION_KEYS)
    end

    def seeded_role_permissions
      ProductRolePermission.where(product_role: seeded_roles)
    end

    def remove_seed_records
      return unless ProductRole.table_exists?

      seeded_role_permissions.delete_all
      seeded_roles.delete_all
      seeded_permissions.delete_all
    end
end
