module AuditEventTestHelper
  # Audit events are protected by an append-only database trigger. Tests that
  # disable transactional cleanup must truncate this synthetic test ledger
  # before deleting referenced tenant records.
  def clear_test_audit_events!
    raise "audit cleanup is test-only" unless Rails.env.test?

    AuditEvent.connection.execute(
      "TRUNCATE TABLE billing_lifecycle_deliveries, audit_events RESTART IDENTITY"
    )
  end
end
