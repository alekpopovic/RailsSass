require "test_helper"

class ModuleBoundariesTest < ActiveSupport::TestCase
  BOUNDARIES = {
    "Accounts" => [],
    "Tenancy" => %w[Accounts],
    "Catalog" => [],
    "Billing" => %w[Tenancy Catalog],
    "Entitlements" => %w[Tenancy Catalog Billing],
    "Access" => %w[Tenancy Catalog Billing Entitlements],
    "Products" => %w[Tenancy Entitlements Access],
    "Platform" => %w[Accounts Tenancy Catalog Billing Entitlements Access Products]
  }.freeze

  test "module dependencies follow the documented direction" do
    BOUNDARIES.each do |source_module, allowed_dependencies|
      assert_empty allowed_dependencies - BOUNDARIES.keys,
        "#{source_module} declares an unknown dependency"

      forbidden_dependencies = BOUNDARIES.keys - allowed_dependencies - [ source_module ]
      next if forbidden_dependencies.empty?

      forbidden_pattern = /\b(?:#{Regexp.union(forbidden_dependencies).source})::/

      module_files(source_module).each do |path|
        assert_no_match forbidden_pattern, path.read,
          "#{path.relative_path_from(Rails.root)} crosses a module boundary"
      end
    end
  end

  private

  def module_files(module_name)
    pattern = Rails.root.join("{app,lib}", "**", module_name.underscore, "**", "*.rb")
    Dir.glob(pattern.to_s).sort.map { |path| Pathname(path) }
  end
end
