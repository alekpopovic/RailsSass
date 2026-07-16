require "test_helper"
require_relative "../../../support/organization_test_helper"

class Billing::Checkouts::ReturnUrlTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    owner = create_test_user(email_address: "return-url-#{SecureRandom.hex(4)}@example.test")
    @organization, = create_test_organization_with_owner(
      owner: owner,
      name: "Return URL Organization",
      slug: "return-url-#{SecureRandom.hex(4)}"
    )
  end

  test "builds only the canonical tenant pending URL from trusted options" do
    url = described_class.call(
      organization: @organization,
      url_options: { host: "app.example.test", protocol: "https" }
    )

    assert_equal "https://app.example.test/o/#{@organization.slug}/billing/checkouts/pending", url
  end

  test "rejects missing malformed and unsafe application origins" do
    unsafe_options = [
      { host: "", protocol: "https" },
      { host: "app.example.test@attacker.test", protocol: "https" },
      { host: "app.example.test", protocol: "javascript" }
    ]

    unsafe_options.each do |url_options|
      assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
        described_class.call(organization: @organization, url_options: url_options)
      end
    end
  end

  private
    def described_class
      Billing::Checkouts::ReturnUrl
    end
end
