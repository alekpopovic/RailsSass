require "test_helper"
require_relative "../../../support/billing_test_helper"
require_relative "../../../support/product_rbac_test_helper"

class Billing::Webhooks::ProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include BillingTestHelper
  include ProductRbacTestHelper

  FakeClient = Struct.new(:snapshot, :environment, :store_id, :error, :calls, keyword_init: true) do
    def retrieve_subscription_snapshot(provider_subscription_id:)
      self.calls ||= []
      calls << provider_subscription_id
      raise error if error

      snapshot
    end
  end

  setup do
    clear_enqueued_jobs
    @organization, @membership = create_billing_tenant(prefix: "webhook-processor")
    @plan = create_test_plan
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: "61001",
      lemon_product_id: unique_numeric_id,
      lemon_variant_id: unique_numeric_id
    )
    @mapping = create_billing_provider_price_mapping(plan_price: @plan_price)
    @token_digest = Digest::SHA256.hexdigest(SecureRandom.urlsafe_base64(32))
    @attempt = create_billing_checkout_attempt(
      organization: @organization,
      membership: @membership,
      plan_price: @plan_price,
      token_digest: @token_digest,
      status: :ready,
      provider_checkout_id: "checkout_#{SecureRandom.hex(8)}",
      expires_at: 30.minutes.from_now
    )
    @locator = create_billing_provider_locator(
      organization: @organization,
      checkout_attempt: @attempt
    )
    @provider_subscription_id = "sub_#{SecureRandom.hex(8)}"
    @provider_customer_id = unique_numeric_id
    @provider_created_at = @attempt.created_at + 1.second
    @initial_updated_at = @provider_created_at + 1.second
    @processing_now = @initial_updated_at + 1.second
  end

  teardown do
    clear_enqueued_jobs
    Current.reset
  end

  test "created event consumes verified checkout authority and atomically creates the local projection" do
    event = created_event
    client = fake_client(snapshot: snapshot)
    job_id = "billing-job-#{SecureRandom.hex(6)}"

    assert_difference -> { Billing::Customer.count }, 1 do
      assert_difference -> { Billing::Subscription.count }, 1 do
        assert_difference -> {
          @organization.audit_events.where(action: "billing.subscription.created").count
        }, 1 do
          result = process(event, client: client, job_id: job_id)

          assert_predicate result, :processed?
        end
      end
    end

    subscription = @organization.billing_subscriptions.find_by!(current: true)
    assert_equal @plan_price, subscription.plan_price
    assert_equal @plan_price, subscription.origin_plan_price
    assert_equal @attempt, subscription.origin_checkout_attempt
    assert_equal @provider_subscription_id, subscription.provider_subscription_id
    assert_equal @initial_updated_at.to_i, subscription.provider_updated_at.to_i
    assert_equal @initial_updated_at.to_i, subscription.last_seen_provider_updated_at.to_i
    assert_predicate subscription, :sync_state_synced?
    assert_predicate event.reload, :status_processed?
    assert_equal @organization, event.organization
    assert_predicate @attempt.reload, :status_completed?
    assert @attempt.token_consumed_at
    assert_predicate @locator.reload, :status_consumed?
    assert_equal subscription, @locator.billing_subscription
    assert_equal @provider_subscription_id, @locator.provider_subscription_id
    assert_equal [ @provider_subscription_id ], client.calls
    audit_event = @organization.audit_events.find_by!(
      action: "billing.subscription.created",
      subject_type: "Billing::Subscription",
      subject_id: subscription.id
    )
    assert_nil audit_event.actor_user
    assert_equal job_id, audit_event.job_id
    assert_equal(
      {
        "plan_price_id" => @plan_price.id,
        "plan_key" => @plan.key,
        "to_status" => "active",
        "environment" => "test",
        "test_mode" => true,
        "webhook_event_id" => event.id
      },
      audit_event.metadata
    )
    delivery = @organization.billing_lifecycle_deliveries.find_by!(
      kind: "subscription_activated",
      source_webhook_event: event,
      recipient_user: @membership.user
    )
    assert_equal audit_event, delivery.audit_event
    assert_equal subscription, delivery.billing_subscription
    assert_enqueued_with(
      job: Billing::DeliverLifecycleEmailJob,
      args: [ @organization.id, delivery.id ],
      queue: "mailers"
    )
  end

  test "duplicate jobs and equal provider snapshots are idempotent" do
    first_event = created_event
    first_client = fake_client(snapshot: snapshot)
    process(first_event, client: first_client)
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    original_lock_version = subscription.lock_version
    original_delivery_count = @organization.billing_lifecycle_deliveries.count

    assert_no_difference -> { @organization.billing_lifecycle_deliveries.count } do
      assert_no_difference -> { @organization.audit_events.count } do
        duplicate_job_result = process(first_event, client: fake_client(snapshot: snapshot))
        assert_equal :noop, duplicate_job_result.status
      end
    end

    second_event = created_event
    assert_no_difference -> { Billing::Subscription.count } do
      assert_no_difference -> { Billing::Customer.count } do
        assert_no_difference -> { @organization.billing_lifecycle_deliveries.count } do
          assert_no_difference -> { @organization.audit_events.count } do
            result = process(second_event, client: fake_client(snapshot: snapshot))
            assert_predicate result, :processed?
          end
        end
      end
    end

    assert_equal 1, original_delivery_count
    assert_predicate second_event.reload, :status_processed?
    assert_equal original_lock_version, subscription.reload.lock_version
  end

  test "an audit persistence failure rolls back a created subscription projection" do
    event = created_event
    invalid_job_id = "j" * (AuditEvent::CORRELATION_ID_MAX_LENGTH + 1)

    assert_no_difference -> { Billing::Subscription.count } do
      assert_no_difference -> { Billing::Customer.count } do
        result = process(event, client: fake_client(snapshot: snapshot), job_id: invalid_job_id)
        assert_equal :failed, result.status
      end
    end

    assert_failed event, "projection_conflict"
    assert_predicate @attempt.reload, :status_ready?
    assert_predicate @locator.reload, :status_unresolved?
  end

  test "a row without signed-ingress provenance cannot be claimed" do
    event = created_event(ingress_version: nil)
    client = fake_client(snapshot: snapshot)

    assert_no_difference -> { Billing::Subscription.count } do
      result = process(event, client: client)
      assert_equal :noop, result.status
    end

    assert_empty client.calls
    assert_predicate event.reload, :status_received?
  end

  test "invalid checkout context and created variant mismatch fail closed" do
    invalid_context_event = created_event(
      "checkout_plan_price_id" => @plan_price.id + 1
    )

    assert_no_difference -> { Billing::Subscription.count } do
      process(invalid_context_event, client: fake_client(snapshot: snapshot))
    end
    assert_failed invalid_context_event, "checkout_context_mismatch"
    assert_predicate @attempt.reload, :status_ready?
    assert_predicate @locator.reload, :status_unresolved?

    mismatch_event = created_event
    mismatch_snapshot = snapshot(provider_variant_id: unique_numeric_id)
    assert_no_difference -> { Billing::Subscription.count } do
      process(mismatch_event, client: fake_client(snapshot: mismatch_snapshot))
    end
    assert_failed mismatch_event, "checkout_variant_mismatch"
    assert_predicate @locator.reload, :status_unresolved?
  end

  test "created projection rejects context that was expired when the event was received" do
    event = created_event(
      "checkout_expires_at" => (@processing_now - 2.seconds).iso8601(6)
    )

    assert_no_difference -> { Billing::Subscription.count } do
      process(event, client: fake_client(snapshot: snapshot))
    end

    assert_failed event, "invalid_checkout_context"
    assert_predicate @attempt.reload, :status_ready?
    assert_predicate @locator.reload, :status_unresolved?
  end

  test "a consumed checkout nonce cannot bind a second provider subscription" do
    process(created_event, client: fake_client(snapshot: snapshot))
    original_subscription = @organization.billing_subscriptions.find_by!(current: true)
    @provider_subscription_id = "sub_#{SecureRandom.hex(8)}"
    event = created_event

    assert_no_difference -> { Billing::Subscription.count } do
      process(event, client: fake_client(snapshot: snapshot))
    end

    assert_failed event, "subscription_locator_invalid"
    assert_equal original_subscription, @locator.reload.billing_subscription
    assert_equal original_subscription.provider_subscription_id,
      @locator.provider_subscription_id
  end

  test "a verified replacement archives expired history without deleting it" do
    old_subscription = create_billing_subscription(
      organization: @organization,
      status: :expired,
      ends_at: @provider_created_at - 1.day,
      provider_updated_at: @provider_created_at - 1.day
    )

    assert_difference -> { Billing::Subscription.count }, 1 do
      process(created_event, client: fake_client(snapshot: snapshot))
    end

    old_subscription.reload
    assert_not_predicate old_subscription, :current?
    assert old_subscription.archived_at
    assert_equal 2, @organization.billing_subscriptions.count
    assert_equal @provider_subscription_id,
      @organization.billing_subscriptions.find_by!(current: true).provider_subscription_id
  end

  test "a rejected archived identity does not archive the current subscription or create a customer" do
    current_subscription = create_billing_subscription(
      organization: @organization,
      status: :expired,
      ends_at: @provider_created_at - 1.day,
      provider_updated_at: @provider_created_at - 1.day
    )
    incoming_customer = create_billing_customer(
      organization: @organization,
      provider_customer_id: @provider_customer_id
    )
    create_billing_subscription(
      organization: @organization,
      billing_customer: incoming_customer,
      provider_subscription_id: @provider_subscription_id,
      provider_customer_id: @provider_customer_id,
      current: false,
      archived_at: @provider_created_at,
      provider_updated_at: @initial_updated_at
    )
    event = created_event

    assert_no_difference -> { Billing::Customer.count } do
      process(event, client: fake_client(snapshot: snapshot))
    end

    assert_failed event, "archived_subscription_conflict"
    assert_predicate current_subscription.reload, :current?
    assert_nil current_subscription.archived_at
  end

  test "an event received before expiry can process later and supersede other pending attempts" do
    event = created_event
    delayed_processing_at = @attempt.expires_at + 11.minutes
    @attempt.update!(status: :expired, completed_at: @attempt.expires_at + 10.minutes)
    competing_attempt = create_billing_checkout_attempt(
      organization: @organization,
      membership: @membership,
      plan_price: @plan_price,
      status: :ready,
      provider_checkout_id: "checkout_#{SecureRandom.hex(8)}",
      expires_at: @attempt.expires_at + 1.hour
    )
    create_billing_provider_locator(
      organization: @organization,
      checkout_attempt: competing_attempt
    )

    process(event, client: fake_client(snapshot: snapshot), now: delayed_processing_at)

    assert_operator event.received_at, :<, @attempt.expires_at
    assert_operator delayed_processing_at, :>, @attempt.expires_at
    assert_predicate competing_attempt.reload, :status_superseded?
    assert competing_attempt.completed_at
    assert_predicate @organization.billing_subscriptions.find_by!(current: true), :status_active?
  end

  test "a second provider subscription cannot replace non-expired current access" do
    current_subscription = create_billing_subscription(organization: @organization)
    event = created_event

    assert_no_difference -> { Billing::Subscription.count } do
      process(event, client: fake_client(snapshot: snapshot))
    end

    assert_failed event, "second_current_subscription"
    assert_predicate current_subscription.reload, :current?
    assert_predicate @attempt.reload, :status_ready?
    assert_predicate @locator.reload, :status_unresolved?
  end

  test "newer updates map statuses and dates while stale events cannot overwrite them" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    past_due_at = @initial_updated_at + 10.seconds

    past_due_event = update_event
    process(
      past_due_event,
      client: fake_client(snapshot: snapshot(status: "past_due", updated_at: past_due_at)),
      now: past_due_at + 1.second
    )
    subscription.reload
    assert_predicate subscription, :status_past_due?
    assert_equal past_due_at.to_i, subscription.past_due_started_at.to_i
    past_due_audit = billing_audit_for(past_due_event, action: "billing.subscription.updated")
    assert_nil past_due_audit.actor_user
    assert_equal "active", past_due_audit.metadata.fetch("from_status")
    assert_equal "past_due", past_due_audit.metadata.fetch("to_status")
    payment_delivery = lifecycle_delivery_for(past_due_event, kind: "payment_problem")
    assert_equal past_due_audit, payment_delivery.audit_event

    later_past_due_at = past_due_at + 10.seconds
    later_past_due_event = update_event
    process(
      later_past_due_event,
      client: fake_client(snapshot: snapshot(status: "past_due", updated_at: later_past_due_at)),
      now: later_past_due_at + 1.second
    )
    assert_equal past_due_at.to_i, subscription.reload.past_due_started_at.to_i
    renewal_audit = billing_audit_for(
      later_past_due_event,
      action: "billing.subscription.updated"
    )
    assert_equal "past_due", renewal_audit.metadata.fetch("from_status")
    assert_equal "past_due", renewal_audit.metadata.fetch("to_status")
    assert_nil lifecycle_delivery_for(later_past_due_event)

    cancelled_at = later_past_due_at + 10.seconds
    access_ends_at = cancelled_at + 1.day
    cancelled_event = update_event
    process(
      cancelled_event,
      client: fake_client(
        snapshot: snapshot(status: "cancelled", updated_at: cancelled_at, ends_at: access_ends_at)
      ),
      now: cancelled_at + 1.second
    )
    subscription.reload
    assert_predicate subscription, :status_cancelled?
    assert_nil subscription.past_due_started_at
    assert_equal access_ends_at.to_i, subscription.ends_at.to_i
    assert_predicate Entitlements::SubscriptionAccessPolicy.new(
      subscription: subscription,
      now: cancelled_at + 1.hour
    ).call, :allowed?
    cancelled_audit = billing_audit_for(
      cancelled_event,
      action: "billing.subscription.cancelled"
    )
    assert_equal "past_due", cancelled_audit.metadata.fetch("from_status")
    assert_equal "cancelled", cancelled_audit.metadata.fetch("to_status")
    assert_equal cancelled_audit,
      lifecycle_delivery_for(cancelled_event, kind: "cancellation_scheduled").audit_event

    stale_event = update_event
    stale_snapshot = snapshot(status: "active", updated_at: later_past_due_at + 1.second)
    process(
      stale_event,
      client: fake_client(snapshot: stale_snapshot),
      now: cancelled_at + 2.seconds
    )
    assert_predicate stale_event.reload, :status_ignored?
    assert_equal "stale_provider_snapshot", stale_event.payload.fetch("reason_code")
    assert_predicate subscription.reload, :status_cancelled?
    assert_nil billing_audit_for(stale_event)

    expired_at = cancelled_at + 20.seconds
    expired_event = update_event
    process(
      expired_event,
      client: fake_client(
        snapshot: snapshot(status: "expired", updated_at: expired_at, ends_at: access_ends_at)
      ),
      now: expired_at + 1.second
    )
    assert_predicate subscription.reload, :status_expired?
    assert_predicate expired_event.reload, :status_processed?
    expired_audit = billing_audit_for(expired_event, action: "billing.subscription.expired")
    assert_equal "cancelled", expired_audit.metadata.fetch("from_status")
    assert_equal "expired", expired_audit.metadata.fetch("to_status")
    assert_equal expired_audit,
      lifecycle_delivery_for(expired_event, kind: "subscription_expired").audit_event
  end

  test "unknown variant and unknown status advance last seen and deny paid access" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    original_price = subscription.plan_price
    unknown_variant_at = @initial_updated_at + 10.seconds
    variant_event = update_event

    process(
      variant_event,
      client: fake_client(
        snapshot: snapshot(provider_variant_id: unique_numeric_id, updated_at: unknown_variant_at)
      ),
      now: unknown_variant_at + 1.second
    )
    subscription.reload
    assert_equal original_price, subscription.plan_price
    assert_predicate subscription, :sync_state_mapping_error?
    assert_equal unknown_variant_at.to_i, subscription.last_seen_provider_updated_at.to_i
    assert_failed variant_event, "unknown_provider_variant"
    variant_audit = billing_audit_for(variant_event, action: "billing.subscription.updated")
    assert_equal "unknown_provider_variant", variant_audit.metadata.fetch("reason_code")
    assert_denied_for_invalid_sync subscription

    unknown_status_at = unknown_variant_at + 10.seconds
    status_event = update_event
    process(
      status_event,
      client: fake_client(snapshot: snapshot(status: "provider_future_state", updated_at: unknown_status_at)),
      now: unknown_status_at + 1.second
    )
    subscription.reload
    assert_predicate subscription, :status_unknown?
    assert_predicate subscription, :sync_state_invalid?
    assert_equal unknown_status_at.to_i, subscription.provider_updated_at.to_i
    assert_failed status_event, "unknown_subscription_status"
    status_audit = billing_audit_for(status_event, action: "billing.subscription.updated")
    assert_equal "active", status_audit.metadata.fetch("from_status")
    assert_equal "unknown", status_audit.metadata.fetch("to_status")
    assert_equal "unknown_subscription_status", status_audit.metadata.fetch("reason_code")
    assert_denied_for_invalid_sync subscription
  end

  test "equal provider timestamps with different critical creation time fail closed" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    event = update_event

    process(
      event,
      client: fake_client(
        snapshot: snapshot(created_at: @provider_created_at - 1.second)
      )
    )

    assert_failed event, "provider_timestamp_conflict"
    assert_predicate subscription.reload, :sync_state_invalid?
    conflict_audit = billing_audit_for(event, action: "billing.subscription.updated")
    assert_equal "provider_timestamp_conflict", conflict_audit.metadata.fetch("reason_code")
  end

  test "a monotonic subscription update applies its matching open plan change atomically" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    target_price, target_mapping = create_mapped_plan_price
    plan_change = create_plan_change(
      subscription: subscription,
      to_plan_price: target_price,
      status: :pending
    )
    updated_at = @initial_updated_at + 10.seconds
    event = update_event
    job_id = "plan-change-job-#{SecureRandom.hex(6)}"

    result = process(
      event,
      client: fake_client(
        snapshot: snapshot(
          provider_variant_id: target_mapping.provider_variant_id,
          updated_at: updated_at
        )
      ),
      now: updated_at + 1.second,
      job_id: job_id
    )

    assert_predicate result, :processed?
    assert_equal target_price, subscription.reload.plan_price
    assert_predicate plan_change.reload, :status_applied?
    assert_equal updated_at.to_i, plan_change.provider_updated_at.to_i
    assert_equal (updated_at + 1.second).to_i, plan_change.completed_at.to_i
    applied_audit = billing_audit_for(event, action: "billing.plan_change.applied")
    assert_nil applied_audit.actor_user
    assert_equal job_id, applied_audit.job_id
    assert_equal(
      {
        "from_plan_price_id" => @plan_price.id,
        "to_plan_price_id" => target_price.id,
        "from_plan_key" => @plan.key,
        "to_plan_key" => target_price.plan.key,
        "environment" => "test",
        "test_mode" => true,
        "webhook_event_id" => event.id
      },
      applied_audit.metadata
    )
    plan_change_delivery = lifecycle_delivery_for(event, kind: "plan_change_completed")
    assert_equal applied_audit, plan_change_delivery.audit_event
    assert_equal subscription, plan_change_delivery.billing_subscription

    completed_at = plan_change.completed_at
    assert_no_difference -> { @organization.audit_events.count } do
      duplicate = process(event, client: fake_client(snapshot: snapshot))
      assert_equal :noop, duplicate.status
    end
    assert_equal completed_at, plan_change.reload.completed_at
  end

  test "a source variant update leaves an open plan change awaiting confirmation" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    target_price, = create_mapped_plan_price
    plan_change = create_plan_change(subscription: subscription, to_plan_price: target_price)
    updated_at = @initial_updated_at + 10.seconds

    event = update_event
    process(
      event,
      client: fake_client(snapshot: snapshot(updated_at: updated_at)),
      now: updated_at + 1.second
    )

    assert_equal @plan_price, subscription.reload.plan_price
    assert_predicate plan_change.reload, :status_submitted?
    assert_nil plan_change.completed_at
  end

  test "a different known variant supersedes an open plan change without rewriting history" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    target_price, = create_mapped_plan_price
    replacement_price, replacement_mapping = create_mapped_plan_price
    plan_change = create_plan_change(subscription: subscription, to_plan_price: target_price)
    updated_at = @initial_updated_at + 10.seconds

    event = update_event
    process(
      event,
      client: fake_client(
        snapshot: snapshot(
          provider_variant_id: replacement_mapping.provider_variant_id,
          updated_at: updated_at
        )
      ),
      now: updated_at + 1.second
    )

    assert_equal replacement_price, subscription.reload.plan_price
    assert_predicate plan_change.reload, :status_superseded?
    assert_equal updated_at.to_i, plan_change.provider_updated_at.to_i
    assert plan_change.completed_at
    failed_audit = billing_audit_for(event, action: "billing.plan_change.failed")
    assert_nil failed_audit.actor_user
    assert_equal "superseded_by_provider_variant",
      failed_audit.metadata.fetch("reason_code")
    assert_equal target_price.id, failed_audit.metadata.fetch("to_plan_price_id")
  end

  test "a verified provider downgrade preserves over-limit product data and assignments" do
    analytics = create_test_product(key: "analytics", name: "Analytics")
    report_limit = create_test_product_feature(
      product: analytics,
      key: "report_limit",
      name: "Report limit",
      kind: :limit
    )
    seat_limit = create_test_product_feature(
      product: analytics,
      key: "seat_limit",
      name: "Seat limit",
      kind: :limit
    )
    source_plan_product = create_test_plan_product(plan: @plan, product: analytics)
    create_test_entitlement(
      plan_product: source_plan_product,
      product_feature: report_limit,
      limit_value: 10
    )
    create_test_entitlement(
      plan_product: source_plan_product,
      product_feature: seat_limit,
      limit_value: 10
    )

    target_plan = create_test_plan(name: "Provider downgrade target")
    target_plan_product = create_test_plan_product(plan: target_plan, product: analytics)
    create_test_entitlement(
      plan_product: target_plan_product,
      product_feature: report_limit,
      limit_value: 1
    )
    create_test_entitlement(
      plan_product: target_plan_product,
      product_feature: seat_limit,
      limit_value: 0
    )
    target_price = create_test_plan_price(
      plan: target_plan,
      lemon_store_id: @mapping.provider_store_id,
      lemon_product_id: @mapping.provider_product_id,
      lemon_variant_id: unique_numeric_id
    )
    target_mapping = create_billing_provider_price_mapping(plan_price: target_price)

    reports = 2.times.map do |index|
      @organization.analytics_reports.create!(
        name: "Retained report #{index}",
        description: "Provider downgrades must not delete product data."
      )
    end
    product_membership = create_test_product_membership(
      organization_membership: @membership,
      product: analytics
    )
    product_role = create_test_product_role(
      product: analytics,
      key: "viewer",
      name: "Viewer"
    )
    role_assignment = create_test_product_membership_role(
      product_membership: product_membership,
      product_role: product_role
    )
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    updated_at = @initial_updated_at + 10.seconds
    assert_empty @organization.billing_plan_changes

    assert_no_difference -> { @organization.analytics_reports.count } do
      assert_no_difference -> { @organization.product_memberships.count } do
        assert_no_difference -> { @organization.product_membership_roles.count } do
          result = process(
            update_event,
            client: fake_client(
              snapshot: snapshot(
                provider_variant_id: target_mapping.provider_variant_id,
                updated_at: updated_at
              )
            ),
            now: updated_at + 1.second
          )

          assert_predicate result, :processed?
        end
      end
    end

    assert_equal target_price, subscription.reload.plan_price
    assert_empty @organization.billing_plan_changes
    assert_equal reports.map(&:id).sort, @organization.analytics_reports.order(:id).pluck(:id)
    assert_predicate product_membership.reload, :active?
    assert_predicate product_role.reload, :active?
    assert_equal role_assignment, @organization.product_membership_roles.find(role_assignment.id)

    Current.organization = @organization
    compatibility = Products::PlanCompatibility.call(
      organization: @organization,
      to_plan: @organization.effective_plan
    )
    issues_by_feature = compatibility.issues.index_by(&:feature_key)
    report_issue = issues_by_feature.fetch("report_limit")
    seat_issue = issues_by_feature.fetch("seat_limit")

    assert_equal target_plan, @organization.effective_plan
    assert_predicate @organization, :over_limit?
    assert_predicate compatibility, :incompatible?
    assert_predicate compatibility, :over_limit?
    assert_predicate report_issue, :over_limit?
    assert_equal 2, report_issue.usage
    assert_equal 1, report_issue.capacity
    assert_predicate seat_issue, :over_limit?
    assert_equal 1, seat_issue.usage
    assert_equal 0, seat_issue.capacity
    assert_equal "seats", seat_issue.unit

    additional_user = create_test_user(
      email_address: "provider-downgrade-seat-#{SecureRandom.hex(5)}@example.test"
    )
    additional_membership = create_test_membership(
      organization: @organization,
      user: additional_user,
      role: :member
    )
    seat_error = assert_no_difference -> { @organization.product_memberships.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        Access::ProductMemberships::Add.new(
          organization_membership_id: additional_membership.id,
          product_id: analytics.id
        ).call
      end
    end
    assert_instance_of Entitlements::OverLimit, seat_error.cause
  end

  test "stale and equal conflicting snapshots cannot confirm an open plan change" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    target_price, target_mapping = create_mapped_plan_price
    plan_change = create_plan_change(subscription: subscription, to_plan_price: target_price)

    stale_event = update_event
    process(
      stale_event,
      client: fake_client(
        snapshot: snapshot(
          provider_variant_id: target_mapping.provider_variant_id,
          updated_at: @initial_updated_at - 1.second
        )
      )
    )
    assert_predicate stale_event.reload, :status_ignored?
    assert_predicate plan_change.reload, :status_submitted?

    equal_event = update_event
    process(
      equal_event,
      client: fake_client(
        snapshot: snapshot(provider_variant_id: target_mapping.provider_variant_id)
      )
    )
    assert_failed equal_event, "provider_timestamp_conflict"
    assert_predicate plan_change.reload, :status_submitted?
    assert_nil plan_change.completed_at
    assert_equal @plan_price, subscription.reload.plan_price
  end

  test "later webhooks cannot regress a terminal applied plan change" do
    create_subscription_projection!
    subscription = @organization.billing_subscriptions.find_by!(current: true)
    target_price, target_mapping = create_mapped_plan_price
    plan_change = create_plan_change(subscription: subscription, to_plan_price: target_price)
    applied_at = @initial_updated_at + 10.seconds

    process(
      update_event,
      client: fake_client(
        snapshot: snapshot(
          provider_variant_id: target_mapping.provider_variant_id,
          updated_at: applied_at
        )
      ),
      now: applied_at + 1.second
    )
    completed_at = plan_change.reload.completed_at

    reverted_at = applied_at + 10.seconds
    process(
      update_event,
      client: fake_client(snapshot: snapshot(updated_at: reverted_at)),
      now: reverted_at + 1.second
    )

    assert_predicate plan_change.reload, :status_applied?
    assert_equal completed_at, plan_change.completed_at
    assert_equal applied_at.to_i, plan_change.provider_updated_at.to_i
    assert_equal @plan_price, subscription.reload.plan_price
  end

  test "payment triggers refetch the authoritative subscription and transient provider failures retry safely" do
    create_subscription_projection!
    recovered_at = @initial_updated_at + 20.seconds
    payment_event = update_event(event_name: "subscription_payment_success")
    timeout = Billing::LemonSqueezy::Errors::TimeoutError.new(
      "Lemon Squeezy request timed out",
      retryable: true
    )

    assert_raises(Billing::Webhooks::Processor::RetryableError) do
      process(payment_event, client: fake_client(error: timeout), now: recovered_at)
    end
    assert_failed payment_event, "provider_temporarily_unavailable"

    result = process(
      payment_event,
      client: fake_client(snapshot: snapshot(status: "active", updated_at: recovered_at)),
      now: recovered_at + 1.second
    )
    assert_predicate result, :processed?
    assert_predicate payment_event.reload, :status_processed?
    assert_predicate @organization.billing_subscriptions.find_by!(current: true), :status_active?
    assert_equal 2, payment_event.attempts_count
  end

  test "payment failure refetch projects past due rather than trusting invoice status" do
    create_subscription_projection!
    past_due_at = @initial_updated_at + 15.seconds
    event = update_event(event_name: "subscription_payment_failed")

    process(
      event,
      client: fake_client(snapshot: snapshot(status: "past_due", updated_at: past_due_at)),
      now: past_due_at + 1.second
    )

    subscription = @organization.billing_subscriptions.find_by!(current: true)
    assert_predicate subscription, :status_past_due?
    assert_equal past_due_at.to_i, subscription.past_due_started_at.to_i
    assert_predicate event.reload, :status_processed?
  end

  test "database transients release the claim for an immediate bounded retry" do
    event = created_event
    deadlock = ActiveRecord::Deadlocked.new("synthetic deadlock")

    assert_raises(Billing::Webhooks::Processor::RetryableError) do
      process(event, client: fake_client(error: deadlock))
    end
    assert_failed event, "database_temporarily_unavailable"

    result = process(event, client: fake_client(snapshot: snapshot))
    assert_predicate result, :processed?
    assert_equal 2, event.reload.attempts_count
  end

  test "retry exhaustion becomes a permanent admin-visible failure" do
    event = created_event
    terminal_at = @processing_now - 1.second
    event.update!(
      status: :failed,
      processing_started_at: terminal_at,
      processed_at: terminal_at,
      failed_at: terminal_at,
      attempts_count: Billing::Webhooks::Processor::MAX_PROCESSING_ATTEMPTS - 1,
      error_code: "provider_temporarily_unavailable",
      error_class: Billing::Webhooks::Processor::RetryableError.name,
      error_message: "Webhook projection will be retried",
      payload: event.payload.merge("reason_code" => "provider_temporarily_unavailable")
    )
    timeout = Billing::LemonSqueezy::Errors::TimeoutError.new(
      "Lemon Squeezy request timed out",
      retryable: true
    )

    result = process(event, client: fake_client(error: timeout))

    assert_equal :failed, result.status
    assert_failed event, "retry_exhausted"
    assert_equal Billing::Webhooks::Processor::MAX_PROCESSING_ATTEMPTS,
      event.attempts_count
  end

  private
    def create_subscription_projection!
      process(created_event, client: fake_client(snapshot: snapshot))
    end

    def create_mapped_plan_price
      price = create_test_plan_price(
        plan: create_test_plan,
        lemon_store_id: @mapping.provider_store_id,
        lemon_product_id: @mapping.provider_product_id,
        lemon_variant_id: unique_numeric_id
      )
      [ price, create_billing_provider_price_mapping(plan_price: price) ]
    end

    def create_plan_change(subscription:, to_plan_price:, status: :submitted)
      @organization.billing_plan_changes.create!(
        billing_subscription: subscription,
        requested_by_membership: @membership,
        from_plan_price: subscription.plan_price,
        to_plan_price: to_plan_price,
        provider: subscription.provider,
        environment: subscription.environment,
        test_mode: subscription.test_mode,
        status: status,
        requested_at: @processing_now,
        provider_updated_at: status == :pending ? nil : @processing_now
      )
    end

    def process(event, client:, now: @processing_now, job_id: nil)
      Billing::Webhooks::Processor.call(
        webhook_event_id: event.id,
        client: client,
        now: now,
        job_id: job_id
      )
    end

    def billing_audit_for(event, action: nil)
      scope = @organization.audit_events
      scope = scope.where(action: action) if action
      scope.detect { |audit_event| audit_event.metadata["webhook_event_id"] == event.id }
    end

    def lifecycle_delivery_for(event, kind: nil)
      scope = @organization.billing_lifecycle_deliveries
        .where(source_webhook_event_id: event.id)
      scope = scope.where(kind: kind) if kind
      scope.first
    end

    def fake_client(snapshot: nil, error: nil)
      FakeClient.new(
        snapshot: snapshot,
        error: error,
        environment: "test",
        store_id: "61001",
        calls: []
      )
    end

    def created_event(
      overrides = {},
      ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION,
      **keyword_overrides
    )
      overrides = overrides.merge(keyword_overrides)

      create_event(
        event_name: "subscription_created",
        payload: {
          "event_name" => "subscription_created",
          "resource_type" => "subscriptions",
          "provider_resource_id" => @provider_subscription_id,
          "provider_subscription_id" => @provider_subscription_id,
          "provider_store_id" => "61001",
          "test_mode" => true,
          "checkout_token_digest" => @token_digest,
          "checkout_organization_public_id" => @organization.public_id,
          "checkout_plan_price_id" => @plan_price.id,
          "checkout_user_id" => @membership.user_id,
          "checkout_expires_at" => @attempt.expires_at.iso8601(6)
        }.merge(overrides),
        ingress_version: ingress_version
      )
    end

    def update_event(event_name: "subscription_updated")
      create_event(
        event_name: event_name,
        payload: {
          "event_name" => event_name,
          "resource_type" => event_name.start_with?("subscription_payment_") ?
            "subscription-invoices" : "subscriptions",
          "provider_resource_id" => "resource_#{SecureRandom.hex(6)}",
          "provider_subscription_id" => @provider_subscription_id,
          "provider_store_id" => "61001",
          "test_mode" => true
        }
      )
    end

    def create_event(
      event_name:,
      payload:,
      ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION
    )
      create_billing_webhook_event(
        event_name: event_name,
        external_resource_type: payload.fetch("resource_type"),
        external_resource_id: payload.fetch("provider_resource_id"),
        snapshot: payload,
        received_at: @processing_now - 1.second,
        verified_at: @processing_now - 1.second,
        ingress_version: ingress_version
      )
    end

    def snapshot(
      status: "active",
      updated_at: @initial_updated_at,
      ends_at: nil,
      provider_variant_id: @mapping.provider_variant_id,
      created_at: @provider_created_at
    )
      trial_ends_at = status == "on_trial" ? updated_at + 7.days : nil
      ends_at ||= updated_at if status == "expired"
      payload = {
        "data" => {
          "type" => "subscriptions",
          "id" => @provider_subscription_id,
          "attributes" => {
            "store_id" => 61_001,
            "customer_id" => @provider_customer_id.to_i,
            "product_id" => @mapping.provider_product_id.to_i,
            "variant_id" => provider_variant_id.to_i,
            "status" => status,
            "card_brand" => "visa",
            "card_last_four" => "4242",
            "pause" => nil,
            "trial_ends_at" => trial_ends_at&.iso8601(6),
            "renews_at" => updated_at + 30.days,
            "ends_at" => ends_at&.iso8601(6),
            "created_at" => created_at.iso8601(6),
            "updated_at" => updated_at.iso8601(6),
            "test_mode" => true
          }
        }
      }
      payload["data"]["attributes"]["renews_at"] =
        payload["data"]["attributes"]["renews_at"].iso8601(6)

      Billing::LemonSqueezy::SubscriptionSnapshot.parse(
        payload: payload,
        expected_subscription_id: @provider_subscription_id,
        expected_store_id: "61001",
        expected_test_mode: true
      )
    end

    def assert_failed(event, error_code)
      event.reload
      assert_predicate event, :status_failed?
      assert_equal error_code, event.error_code
      assert_equal error_code, event.payload.fetch("reason_code")
      assert event.failed_at
    end

    def assert_denied_for_invalid_sync(subscription)
      result = Entitlements::SubscriptionAccessPolicy.new(subscription: subscription).call
      assert_predicate result, :denied?
      assert_equal :subscription_sync_invalid, result.reason_code
    end

    def unique_numeric_id
      SecureRandom.random_number(8_000_000_000).then { |value| (value + 1_000_000_000).to_s }
    end
end
