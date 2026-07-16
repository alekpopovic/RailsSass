module Organizations::AuditEventsHelper
  ACTION_LABELS = {
    "organization.created" => "Organization created",
    "organization.settings.updated" => "Organization settings updated",
    "organization.invitation.created" => "Invitation sent",
    "organization.invitation.sent" => "Invitation sent",
    "organization.invitation.resent" => "Invitation resent",
    "organization.invitation.accepted" => "Invitation accepted",
    "organization.invitation.revoked" => "Invitation revoked",
    "organization.invitation.expired" => "Invitation expired",
    "organization.membership.created" => "Member added",
    "organization.membership.reactivated" => "Member reactivated",
    "organization.membership.suspended" => "Member suspended",
    "organization.membership.role_changed" => "Member role changed",
    "product.membership.created" => "Product member added",
    "product.membership.removed" => "Product member removed",
    "product.membership.suspended" => "Product member suspended",
    "product.membership.reactivated" => "Product member reactivated",
    "product.membership.role_assigned" => "Product role assigned",
    "product.membership.role_unassigned" => "Product role unassigned",
    "billing.checkout.started" => "Checkout started",
    "billing.subscription.created" => "Subscription created",
    "billing.subscription.updated" => "Subscription updated",
    "billing.subscription.cancelled" => "Subscription cancellation scheduled",
    "billing.subscription.expired" => "Subscription expired",
    "billing.plan_change.requested" => "Plan change requested",
    "billing.plan_change.applied" => "Plan change applied",
    "billing.plan_change.failed" => "Plan change failed"
  }.freeze

  SUBJECT_LABELS = {
    "Organization" => "Organization",
    "OrganizationInvitation" => "Invitation",
    "OrganizationMembership" => "Organization membership",
    "ProductMembership" => "Product membership",
    "Billing::CheckoutAttempt" => "Checkout attempt",
    "Billing::Subscription" => "Subscription",
    "Billing::PlanChange" => "Plan change"
  }.freeze

  SAFE_KEY_PATTERN = /\A[a-z][a-z0-9_]*\z/
  SAFE_STATUS_PATTERN = /\A[a-z][a-z0-9_]*\z/
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def audit_event_action_label(event)
    ACTION_LABELS.fetch(event.action, "Organization activity")
  end

  def audit_event_subject_label(event)
    label = SUBJECT_LABELS.fetch(event.subject_type, "Organization record")
    "#{label} ##{event.subject_id}"
  end

  def audit_event_metadata_details(event)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.stringify_keys : {}

    [
      safe_role_detail(metadata, "organization_role", "Role"),
      safe_role_detail(metadata, "from_role", "Previous role"),
      safe_role_detail(metadata, "to_role", "New role"),
      safe_positive_integer_detail(metadata, "membership_id", "Membership"),
      safe_key_detail(metadata, "product_key", "Product"),
      safe_key_detail(metadata, "product_role_key", "Product role"),
      safe_key_detail(metadata, "plan_key", "Plan"),
      safe_key_detail(metadata, "from_plan_key", "Previous plan"),
      safe_key_detail(metadata, "to_plan_key", "New plan"),
      safe_positive_integer_detail(metadata, "plan_price_id", "Plan price"),
      safe_status_detail(metadata, "status", "Status"),
      safe_status_detail(metadata, "from_status", "Previous status"),
      safe_status_detail(metadata, "to_status", "New status"),
      safe_uuid_detail(metadata, "public_id", "Public ID")
    ].compact
  end

  private
    def safe_role_detail(metadata, key, label)
      value = metadata[key].to_s
      return unless OrganizationMembership.roles.key?(value)

      [ label, value.humanize ]
    end

    def safe_positive_integer_detail(metadata, key, label)
      value = metadata[key]
      return unless value.is_a?(Integer) && value.positive?

      [ label, "##{value}" ]
    end

    def safe_key_detail(metadata, key, label)
      value = metadata[key].to_s
      return unless SAFE_KEY_PATTERN.match?(value)

      [ label, value.humanize ]
    end

    def safe_status_detail(metadata, key, label)
      value = metadata[key].to_s
      return unless SAFE_STATUS_PATTERN.match?(value)

      [ label, value.humanize ]
    end

    def safe_uuid_detail(metadata, key, label)
      value = metadata[key].to_s
      return unless UUID_PATTERN.match?(value)

      [ label, value ]
    end
end
