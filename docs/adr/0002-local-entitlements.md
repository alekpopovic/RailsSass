# ADR 0002: Use Local Subscription and Entitlement State for Authorization

Status: Accepted
Date: 2026-07-15

## Context

Product access depends on an organization's Lemon Squeezy subscription, exact
local plan, product/feature entitlements, product membership, and permission.
Calling Lemon Squeezy while authorizing a request would add network latency,
provider availability, rate limiting, and inconsistent point-in-time behavior
to every protected action.

Checkout redirects and outbound provider API responses are browser/request
events that can be replayed, spoofed, interrupted, or observed before provider
webhooks. They are not trustworthy subscription lifecycle signals.

## Decision

Use PostgreSQL as the only runtime source for subscription eligibility and plan
entitlements.

- `Billing::Subscription` is a local projection of the provider subscription
  and references an exact `PlanPrice` and `Plan` through an exact
  environment-qualified provider mapping.
- The current catalog `PlanPrice` fields are not sufficient production mapping
  evidence because they have no test/live environment dimension. Billing must
  add that isolation before checkout or webhook projection is exposed.
- Plan and price `active` flags stop new selection but do not revoke or rewrite
  an already synchronized subscription.
- The current synchronized subscription plus the canonical status/time matrix in
  [Billing Model](../billing_model.md#8-subscription-access-matrix) yields either
  one effective plan or no plan.
- `Plan.free` is catalog metadata only. There is no automatic free/manual
  fallback plan in the MVP.
- Product authorization composes the local subscription result with plan
  product/feature entitlements and product RBAC.
- Runtime authorization makes no provider HTTP request.
- A checkout return, portal visit, or successful outbound provider command may
  update a separate pending display state but never subscription, plan, or
  entitlement state.
- Only asynchronous processing rooted in a verified, durably persisted,
  idempotent Lemon Squeezy webhook may change `Billing::Subscription`.
- Webhook processing may fetch the current provider resource from a fixed API
  endpoint to coalesce reordered events, but that mutation authority exists only
  because a verified event initiated it.
- A read-only reconciliation job may detect drift and alert. Repair requires a
  provider resend or reprocessing of an already verified event; reconciliation
  alone does not write subscription state.

Unknown/malformed status, variant, plan, environment, timestamp, or conflicting
projection fails closed. Catalog entitlement changes are reviewed,
deployment-controlled local changes; they never mutate subscription state or
derive authority from a browser redirect/provider command response.

## Consequences

### Positive

- Authorization is fast, deterministic, testable, and available during Lemon
  Squeezy outages.
- Redirect spoofing and provider latency cannot grant access.
- One transaction can update subscription projection and event state.
- Stable plan/product/feature keys keep authorization independent of display
  names and provider availability.
- Duplicate/out-of-order webhook behavior is reproducible in Minitest.

### Negative

- Local state can lag provider state until a webhook is processed.
- Webhook receipt, queue health, retries, quarantine, and drift monitoring become
  production-critical.
- Fail-closed mapping errors can temporarily deny legitimate customers.
- Because the flat plan catalog is not versioned, changing a plan's entitlement
  rows affects every synchronized subscription that references that plan. Such
  changes require explicit review and audit; future immutable plan versioning
  would require a separate migration and ADR update.
- Status time bounds and the 15-day past-due policy require consistent clocks and
  deterministic boundary tests.
- Operators cannot “quick fix” access with an unverified database edit.

## Operational requirements

- Verify exact raw-body HMAC before parsing.
- Persist a unique local content fingerprint before HTTP 200.
- Run a dedicated Solid Queue worker and receipt sweeper.
- Alert on aged/unprocessed/quarantined events and sync conflicts.
- Maintain separate test/live mappings and secrets.
- Provide verified-event replay and provider-resend runbooks.
- Test that authorization performs zero provider calls.

## Alternatives considered

### Provider API lookup on every protected request

Rejected because it couples security decisions to external latency, rate limits,
availability, and transient response differences.

### Trust checkout redirect/API success

Rejected because neither is a verified asynchronous lifecycle notification and
both can arrive before or without final subscription state.

### Reconciliation writes local state directly

Rejected by the webhook-authority invariant. It would create a second mutation
path with different provenance and replay semantics.

### Copy all entitlements onto each organization

Rejected for MVP because it creates duplicated mutable entitlement truth.
Subscriptions reference one stable-keyed local plan through the verified
provider projection; authorization reads that plan's normalized entitlement
graph.

## Revisit triggers

- Supporting free/manual grants requires a separate, auditable local grant model
  and ADR; it must not overload subscription state.
- Requiring immutable historical offerings would add plan versions and an
  explicit subscription/price migration rather than renaming a stable key.
- Extracting Billing requires a durable local projection with the same runtime
  contract.
- Provider migration requires dual-ingestion and explicit plan mapping; runtime
  remains local.
