require "test_helper"
require "timeout"
require_relative "../../../support/billing_test_helper"

class Billing::Webhooks::ProcessorConcurrencyTest < ActiveSupport::TestCase
  include BillingTestHelper

  self.use_transactional_tests = false

  class BlockingClient
    attr_reader :environment, :store_id

    def initialize(snapshot:)
      @snapshot = snapshot
      @environment = "test"
      @store_id = snapshot.provider_store_id
      @entered = Queue.new
      @release = Queue.new
      @calls = 0
      @mutex = Mutex.new
    end

    def retrieve_subscription_snapshot(provider_subscription_id:)
      raise "unexpected subscription identity" unless provider_subscription_id == @snapshot.provider_subscription_id

      @mutex.synchronize { @calls += 1 }
      @entered << true
      @release.pop
      @snapshot
    end

    def wait_until_called
      Timeout.timeout(5) { @entered.pop }
    end

    def release
      @release << true
    end

    def call_count
      @mutex.synchronize { @calls }
    end
  end

  setup do
    suffix = SecureRandom.hex(6)
    @organization, @membership = create_billing_tenant(prefix: "webhook-race-#{suffix}")
    @plan = create_test_plan(name: "Webhook Race Plan")
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: "61001",
      lemon_product_id: unique_numeric_id,
      lemon_variant_id: unique_numeric_id
    )
    @mapping = create_billing_provider_price_mapping(plan_price: @plan_price)
    @attempt = create_billing_checkout_attempt(
      organization: @organization,
      membership: @membership,
      plan_price: @plan_price,
      status: :ready,
      provider_checkout_id: "checkout_#{SecureRandom.hex(8)}",
      expires_at: 30.minutes.from_now
    )
    @locator = create_billing_provider_locator(
      organization: @organization,
      checkout_attempt: @attempt
    )
    @subscription_id = "sub_#{SecureRandom.hex(8)}"
    @customer_id = unique_numeric_id
    @now = @attempt.created_at + 5.seconds
    @snapshot = subscription_snapshot
    @event = created_event
    @client = BlockingClient.new(snapshot: @snapshot)
  end

  teardown do
    Current.reset
    cleanup_records
  end

  test "parallel jobs claim and project one verified event exactly once" do
    start = Queue.new
    outcomes = Queue.new
    threads = 2.times.map do
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          outcomes << Billing::Webhooks::Processor.call(
            webhook_event_id: @event.id,
            client: @client,
            now: @now
          )
        end
      rescue StandardError => error
        outcomes << error
      ensure
        Current.reset
      end
    end

    2.times { start << true }
    @client.wait_until_called
    first_outcome = Timeout.timeout(5) { outcomes.pop }
    @client.release
    Timeout.timeout(5) { threads.each(&:join) }
    results = [ first_outcome, Timeout.timeout(5) { outcomes.pop } ]

    assert_empty results.grep(StandardError)
    assert_equal 1, results.count { |result| result.respond_to?(:processed?) && result.processed? }
    assert_equal 1, results.count { |result| result.status == :noop }
    assert_equal 1, @client.call_count
    assert_equal 1, @organization.billing_subscriptions.count
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    assert_equal @attempt.id, subscription.origin_checkout_attempt_id
    assert_equal subscription.id, @locator.reload.billing_subscription_id
    assert_predicate @event.reload, :status_processed?
  ensure
    @client&.release
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  private
    def subscription_snapshot
      created_at = @attempt.created_at + 1.second
      Billing::LemonSqueezy::SubscriptionSnapshot.parse(
        payload: {
          "data" => {
            "type" => "subscriptions",
            "id" => @subscription_id,
            "attributes" => {
              "store_id" => 61_001,
              "customer_id" => @customer_id.to_i,
              "product_id" => @mapping.provider_product_id.to_i,
              "variant_id" => @mapping.provider_variant_id.to_i,
              "status" => "active",
              "card_brand" => "",
              "card_last_four" => "",
              "pause" => nil,
              "trial_ends_at" => nil,
              "renews_at" => (created_at + 30.days).iso8601(6),
              "ends_at" => nil,
              "created_at" => created_at.iso8601(6),
              "updated_at" => (created_at + 1.second).iso8601(6),
              "test_mode" => true
            }
          }
        },
        expected_subscription_id: @subscription_id,
        expected_store_id: "61001",
        expected_test_mode: true
      )
    end

    def created_event
      create_billing_webhook_event(
        event_name: "subscription_created",
        external_resource_type: "subscriptions",
        external_resource_id: @subscription_id,
        received_at: @now - 1.second,
        verified_at: @now - 1.second,
        snapshot: {
          "event_name" => "subscription_created",
          "resource_type" => "subscriptions",
          "provider_resource_id" => @subscription_id,
          "provider_subscription_id" => @subscription_id,
          "provider_store_id" => "61001",
          "test_mode" => true,
          "checkout_token_digest" => @attempt.token_digest,
          "checkout_organization_public_id" => @organization.public_id,
          "checkout_plan_price_id" => @plan_price.id,
          "checkout_user_id" => @membership.user_id,
          "checkout_expires_at" => @attempt.expires_at.iso8601(6)
        }
      )
    end

    def cleanup_records
      return unless @organization

      connection = Billing::Subscription.connection
      connection.execute(
        "ALTER TABLE billing_subscriptions " \
          "DISABLE TRIGGER billing_subscription_history_is_preserved"
      )
      user_ids = OrganizationMembership.where(organization_id: @organization.id).pluck(:user_id)
      ApplicationRecord.transaction do
        Billing::ProviderLocator.where(organization_id: @organization.id).delete_all
        Billing::WebhookEvent.where(id: @event&.id).delete_all
        Billing::Subscription.where(organization_id: @organization.id).delete_all
        Billing::Customer.where(organization_id: @organization.id).delete_all
        Billing::CheckoutAttempt.where(organization_id: @organization.id).delete_all
        Billing::ProviderPriceMapping.where(plan_price_id: @plan_price&.id).delete_all
        PlanPrice.where(id: @plan_price&.id).delete_all
        Plan.where(id: @plan&.id).delete_all
        OrganizationMembership.where(organization_id: @organization.id).delete_all
        Organization.where(id: @organization.id).delete_all
        User.where(id: user_ids).delete_all
      end
    ensure
      connection&.execute(
        "ALTER TABLE billing_subscriptions " \
          "ENABLE TRIGGER billing_subscription_history_is_preserved"
      )
    end

    def unique_numeric_id
      SecureRandom.random_number(8_000_000_000).then { |value| (value + 1_000_000_000).to_s }
    end
end
