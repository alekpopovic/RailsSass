ENV["RAILS_ENV"] ||= "test"

require "webmock/minitest"

WebMock.disable_net_connect!(allow_localhost: true)

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    parallelize(workers: [ ENV.fetch("TEST_WORKERS", "1").to_i, 1 ].max)

    setup do
      Rails.cache.clear
    end
  end
end
