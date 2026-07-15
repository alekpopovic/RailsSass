ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    parallelize(workers: [ ENV.fetch("TEST_WORKERS", "1").to_i, 1 ].max)
  end
end
