require "test_helper"
require_relative "../../../support/billing_test_helper"
require_relative "../../../support/audit_event_test_helper"

class Billing::Checkouts::ConcurrencyTest < ActiveSupport::TestCase
  include BillingTestHelper
  include AuditEventTestHelper

  self.use_transactional_tests = false

  class RecordingClient
    attr_reader :environment, :store_id

    def initialize(store_id:)
      @environment = "test"
      @store_id = store_id
      @calls = 0
      @mutex = Mutex.new
    end

    def create_checkout(variant_id:, expires_at:, **)
      @mutex.synchronize { @calls += 1 }
      Billing::LemonSqueezy::Client::CheckoutResult.new(
        provider_checkout_id: SecureRandom.uuid,
        checkout_url: "https://checkout.example.test/checkout/custom/#{SecureRandom.uuid}?signature=synthetic",
        store_id: store_id,
        variant_id: variant_id,
        test_mode: true,
        expires_at: expires_at
      )
    end

    def call_count
      @mutex.synchronize { @calls }
    end
  end

  setup do
    suffix = SecureRandom.hex(6)
    @user = create_test_user(email_address: "checkout-race-#{suffix}@example.test")
    @organization, @membership = create_test_organization_with_owner(
      owner: @user,
      name: "Checkout Race Organization",
      slug: "checkout-race-#{suffix}"
    )
    @session, = Session.issue_for!(@user, ip_address: nil, user_agent: "Checkout race test")
    @plan = create_test_plan(name: "Checkout Race Plan")
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: "510001",
      lemon_product_id: "520002",
      lemon_variant_id: "530003"
    )
    create_billing_provider_price_mapping(plan_price: @plan_price)
    @client = RecordingClient.new(store_id: @plan_price.lemon_store_id)
  end

  teardown do
    Current.reset
    cleanup_records
  end

  test "two simultaneous submissions create one local attempt and one provider checkout" do
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = 2.times.map do
      Thread.new do
        ready << true
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          user = User.find(@user.id)
          session = Session.find(@session.id)
          organization = Organization.find(@organization.id)
          membership = organization.organization_memberships.find(@membership.id)
          plan_price = PlanPrice.find(@plan_price.id)
          Current.set(session: session, organization: organization, membership: membership) do
            outcomes << Billing::Checkouts::Create.new(
              organization: organization,
              user: user,
              plan_price: plan_price,
              client: @client
            ).call
          end
        end
      rescue StandardError => error
        outcomes << error
      ensure
        Current.reset
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    results = 2.times.map { outcomes.pop }

    assert_equal 1, results.count { |result| result.is_a?(Billing::Checkouts::Create::Result) }
    assert_equal 1, results.count { |result| result.is_a?(Billing::Checkouts::Create::CheckoutPending) }
    assert_equal 1, @client.call_count
    assert_equal 1, @organization.billing_checkout_attempts.count
    assert_equal 1, @organization.billing_provider_locators.count
  end

  private
    def cleanup_records
      clear_test_audit_events!
      ApplicationRecord.transaction do
        Billing::ProviderLocator.where(organization_id: @organization&.id).delete_all
        Billing::CheckoutAttempt.where(organization_id: @organization&.id).delete_all
        Billing::ProviderPriceMapping.where(plan_price_id: @plan_price&.id).delete_all
        PlanPrice.where(id: @plan_price&.id).delete_all
        Plan.where(id: @plan&.id).delete_all
        OrganizationMembership.where(organization_id: @organization&.id).delete_all
        Organization.where(id: @organization&.id).delete_all
        Session.where(id: @session&.id).delete_all
        User.where(id: @user&.id).delete_all
      end
    end
end
