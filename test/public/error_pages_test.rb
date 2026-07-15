require "test_helper"

class ErrorPagesTest < ActiveSupport::TestCase
  ERROR_PAGES = {
    "400.html" => "Bad request",
    "403.html" => "Access denied",
    "404.html" => "Page not found",
    "406-unsupported-browser.html" => "Browser not supported",
    "422.html" => "Request rejected",
    "500.html" => "Something went wrong"
  }.freeze

  test "static error pages are standalone and safe" do
    ERROR_PAGES.each do |filename, heading|
      path = Rails.root.join("public", filename)

      assert path.file?, "expected #{filename} to exist"

      html = path.read
      assert_includes html, "<html lang=\"en\">"
      assert_includes html, "<meta name=\"robots\" content=\"noindex, nofollow\">"
      assert_includes html, "<h1>#{heading}</h1>"
      assert_no_match(/application owner|check the logs/i, html)
    end
  end
end
