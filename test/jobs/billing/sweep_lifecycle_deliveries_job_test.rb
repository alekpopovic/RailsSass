require "test_helper"
require_relative "../../support/billing_lifecycle_delivery_test_helper"

class Billing::SweepLifecycleDeliveriesJobTest < ActiveJob::TestCase
  include BillingLifecycleDeliveryTestHelper

  teardown { Current.reset }

  test "enumerates organization roots and re-resolves each delivery through Current organization" do
    first_organization, _, _, _, _, first_delivery = create_lifecycle_delivery_context
    second_organization, _, _, _, _, second_delivery = create_lifecycle_delivery_context
    calls = []
    original_call = Billing::LifecycleDeliveries::Enqueue.method(:call)
    Billing::LifecycleDeliveries::Enqueue.define_singleton_method(:call) do |**arguments|
      scoped_delivery = Current.organization.billing_lifecycle_deliveries.find(
        arguments.fetch(:delivery_id)
      )
      calls << [ Current.organization.id, scoped_delivery.organization_id ]
      true
    end

    Billing::SweepLifecycleDeliveriesJob.perform_now(now: 1.minute.from_now)

    assert_includes calls, [ first_organization.id, first_organization.id ]
    assert_includes calls, [ second_organization.id, second_organization.id ]
    assert_equal calls.map(&:first), calls.map(&:last)
    assert_nil Current.organization
  ensure
    Billing::LifecycleDeliveries::Enqueue.define_singleton_method(:call, original_call) if original_call
  end

  test "redelivers an abandoned processing lease" do
    organization, _, _, _, _, delivery = create_lifecycle_delivery_context
    future_claim = 1.minute.from_now
    delivery.update!(
      status: "processing",
      attempts_count: 1,
      enqueued_at: future_claim,
      claimed_at: future_claim
    )
    sweep_time = future_claim + Billing::SweepLifecycleDeliveriesJob::REDISPATCH_DELAY + 1.second
    calls = []
    original_call = Billing::LifecycleDeliveries::Enqueue.method(:call)
    Billing::LifecycleDeliveries::Enqueue.define_singleton_method(:call) do |**arguments|
      calls << [ Current.organization.id, arguments ]
      true
    end

    Billing::SweepLifecycleDeliveriesJob.perform_now(now: sweep_time)

    assert_predicate calls, :one?
    assert_equal organization.id, calls.first.first
    assert_equal delivery.id, calls.first.last.fetch(:delivery_id)
    assert_equal sweep_time - Billing::SweepLifecycleDeliveriesJob::REDISPATCH_DELAY,
      calls.first.last.fetch(:redispatch_before)
  ensure
    Billing::LifecycleDeliveries::Enqueue.define_singleton_method(:call, original_call) if original_call
  end
end
