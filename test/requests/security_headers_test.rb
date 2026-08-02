require "test_helper"
require_relative "../support/authentication_test_helper"
require_relative "../support/organization_test_helper"

class SecurityHeadersTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper
  include OrganizationTestHelper

  test "HTML responses enforce the browser security policy with a fresh script nonce" do
    get root_path

    assert_response :success
    assert_equal "DENY", response.headers["X-Frame-Options"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "none", response.headers["X-Permitted-Cross-Domain-Policies"]
    assert_equal "strict-origin-when-cross-origin", response.headers["Referrer-Policy"]
    assert_equal "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
      response.headers["Permissions-Policy"]

    first_nonce = csp_nonce
    assert first_nonce.present?
    assert_csp_policy(first_nonce)
    assert_select "script[nonce='#{first_nonce}']", minimum: 2
    assert_select "script:not([nonce])", count: 0

    get root_path

    assert_response :success
    assert_not_equal first_nonce, csp_nonce
  end

  test "tenant-controlled text remains escaped under the enforced policy" do
    owner = create_test_user(email_address: "xss-owner@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: owner,
      name: %(<script>alert("tenant-xss")</script>),
      slug: "xss-organization"
    )
    membership.create_organization_access_locator!(
      organization: organization,
      user: owner
    )
    sign_in_as(owner)

    get organization_dashboard_path(organization_slug: organization.slug)

    assert_response :success
    assert_no_match(/<script>alert\("tenant-xss"\)<\/script>/, response.body)
    assert_includes response.body, "&lt;script&gt;alert(&quot;tenant-xss&quot;)&lt;/script&gt;"
  end

  private
    def csp_nonce
      response.headers.fetch("Content-Security-Policy")
        .match(/script-src 'self' 'nonce-([^']+)'/)&.captures&.first
    end

    def assert_csp_policy(nonce)
      policy = response.headers.fetch("Content-Security-Policy")

      assert_includes policy, "default-src 'self'"
      assert_includes policy, "base-uri 'none'"
      assert_includes policy, "form-action 'self'"
      assert_includes policy, "frame-ancestors 'none'"
      assert_includes policy, "object-src 'none'"
      assert_includes policy, "script-src 'self' 'nonce-#{nonce}'"
      assert_includes policy, "style-src 'self'"
      assert_not_includes policy, "unsafe-inline"
      assert_nil response.headers["Content-Security-Policy-Report-Only"]
    end
end
