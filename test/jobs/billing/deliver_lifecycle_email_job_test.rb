require "test_helper"
require "stringio"
require_relative "../../support/billing_lifecycle_delivery_test_helper"

class Billing::DeliverLifecycleEmailJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include BillingLifecycleDeliveryTestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
    Current.reset
  end

  test "enqueues after persistence and delivers a recipient row only once" do
    organization, _, _, _, _, delivery = create_lifecycle_delivery_context
    Current.organization = organization

    assert_enqueued_with(
      job: Billing::DeliverLifecycleEmailJob,
      args: [ organization.id, delivery.id ],
      queue: "mailers"
    ) do
      assert Billing::LifecycleDeliveries::Enqueue.call(delivery_id: delivery.id)
    end

    Billing::DeliverLifecycleEmailJob.perform_now(organization.id, delivery.id)
    Billing::DeliverLifecycleEmailJob.perform_now(organization.id, delivery.id)

    assert_predicate delivery.reload, :status_delivered?
    assert_equal 1, delivery.attempts_count
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_nil Current.organization
  end

  test "rechecks recipient eligibility and discards a suspended billing recipient" do
    organization, owner_membership, subscription, webhook_event, audit_event, =
      create_lifecycle_delivery_context
    recipient = create_test_user(
      email_address: "lifecycle-suspended-#{SecureRandom.hex(6)}@example.test"
    )
    membership = create_test_membership(
      organization: organization,
      user: recipient,
      role: :billing
    )
    delivery = organization.billing_lifecycle_deliveries.create!(
      audit_event: audit_event,
      billing_subscription: subscription,
      source_webhook_event: webhook_event,
      recipient_user: recipient,
      kind: :payment_problem,
      available_at: Time.current
    )
    organization.organization_memberships
      .where(id: membership.id)
      .update_all(status: "suspended", updated_at: Time.current)

    Billing::DeliverLifecycleEmailJob.perform_now(organization.id, delivery.id)

    assert_predicate delivery.reload, :status_discarded?
    assert_equal "recipient_ineligible", delivery.failure_code
    assert_empty ActionMailer::Base.deliveries
    assert_predicate owner_membership.reload, :active?
  end

  test "terminal delivery failure is redacted and discarded at the attempt cap" do
    organization, _, _, _, _, delivery = create_lifecycle_delivery_context
    delivery.update!(attempts_count: Billing::LifecycleDelivery::MAX_ATTEMPTS - 1)
    sensitive_error = "smtp failed for private@example.test token=secret-value"
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    original_with = Billing::LifecycleMailer.method(:with)
    Billing::LifecycleMailer.define_singleton_method(:with) do |**|
      raise StandardError, sensitive_error
    end

    assert_no_enqueued_jobs do
      Billing::DeliverLifecycleEmailJob.perform_now(organization.id, delivery.id)
    end

    assert_predicate delivery.reload, :status_discarded?
    assert_equal Billing::LifecycleDelivery::MAX_ATTEMPTS, delivery.attempts_count
    assert_equal "retry_exhausted", delivery.failure_code
    assert_not_includes output.string, sensitive_error
    assert_not_includes output.string, "private@example.test"
    assert_not_includes output.string, "secret-value"
  ensure
    Billing::LifecycleMailer.define_singleton_method(:with, original_with) if original_with
    Rails.logger = previous_logger if previous_logger
  end
end
