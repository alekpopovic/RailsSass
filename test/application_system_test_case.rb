require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    if ENV["CI"] || ENV["SYSTEM_TEST_CHROME_NO_SANDBOX"] == "1"
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")
    end
  end
end

Selenium::WebDriver.logger.level = :warn
