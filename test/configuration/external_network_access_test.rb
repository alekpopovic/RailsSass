require "test_helper"

class ExternalNetworkAccessTest < ActiveSupport::TestCase
  test "test suite rejects unstubbed external network access" do
    error = assert_raises(WebMock::NetConnectNotAllowedError) do
      Net::HTTP.get(URI("https://example.invalid/billing-test"))
    end

    assert_includes error.message, "Real HTTP connections are disabled"
  end
end
