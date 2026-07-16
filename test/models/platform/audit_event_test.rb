require "test_helper"
require_relative "../../support/authentication_test_helper"
require_relative "../../support/catalog_test_helper"

class Platform::AuditEventTest < ActiveSupport::TestCase
  include AuthenticationTestHelper
  include CatalogTestHelper

  setup do
    @actor = create_test_user(email_address: "platform-audit-actor@example.test")
    @actor.update!(system_role: :platform_admin)
    @product = create_test_product
  end

  test "belongs to the platform actor and stores a bounded catalog subject" do
    event = create_event

    assert_equal @actor, event.actor_user
    assert_equal @product.id, event.subject_id
    assert_equal @product.key, event.subject_key
    assert_includes @actor.platform_audit_events_as_actor, event
  end

  test "validates fixed actions subjects keys and object change sets" do
    event = Platform::AuditEvent.new(
      actor_user: @actor,
      action: "catalog.deleted",
      subject_type: "User",
      subject_id: 0,
      subject_key: "  ",
      change_set: [ "not", "an", "object" ],
      occurred_at: Time.current
    )

    assert_not event.valid?
    assert_includes event.errors[:action], "is not included in the list"
    assert_includes event.errors[:subject_type], "is not included in the list"
    assert_includes event.errors[:subject_id], "must be greater than 0"
    assert_predicate event.errors[:subject_key], :any?
    assert_includes event.errors[:change_set], "must be an object"
  end

  test "rejects an oversized change set before persistence" do
    event = build_event(change_set: { "description" => "x" * 17_000 })

    assert_not event.valid?
    assert_includes event.errors[:change_set], "is too large"
  end

  test "requires a verified enabled platform administrator as actor" do
    ordinary_user = create_test_user(email_address: "ordinary-platform-audit@example.test")
    event = build_event(actor_user: ordinary_user)

    assert_not event.valid?
    assert_includes event.errors[:actor_user], "must be an active platform administrator"
  end

  test "persisted events are readonly through Active Record" do
    event = create_event

    assert_predicate event, :readonly?
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      event.update!(action: "catalog.deactivated")
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
  end

  test "database trigger rejects direct update" do
    event = create_event
    update_error = assert_raises(ActiveRecord::StatementInvalid) do
      Platform::AuditEvent.where(id: event.id)
        .update_all(action: "catalog.deactivated")
    end
    assert_kind_of PG::ObjectNotInPrerequisiteState, update_error.cause
  end

  test "database trigger rejects direct delete" do
    event = create_event
    delete_error = assert_raises(ActiveRecord::StatementInvalid) do
      Platform::AuditEvent.where(id: event.id).delete_all
    end
    assert_kind_of PG::ObjectNotInPrerequisiteState, delete_error.cause
  end

  private
    def create_event(**overrides)
      Platform::AuditEvent.create!(event_attributes.merge(overrides))
    end

    def build_event(**overrides)
      Platform::AuditEvent.new(event_attributes.merge(overrides))
    end

    def event_attributes
      {
        actor_user: @actor,
        action: "catalog.updated",
        subject_type: "Product",
        subject_id: @product.id,
        subject_key: @product.key,
        change_set: { "name" => { "from" => "Old", "to" => "New" } },
        occurred_at: Time.current
      }
    end
end
