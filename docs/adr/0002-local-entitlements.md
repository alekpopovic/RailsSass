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

Implementation note (2026-07-16): the repository has added constrained Billing
persistence/history tables, exact test/live provider price mappings, a
checkout-token provider locator, the Lemon API adapter, owner/billing checkout
with local pending state, and the read-only `Entitlements` status/catalog
resolver. The central `Access::Gate` composes that resolver with live product
membership and permission state without provider I/O. The application now has
verified webhook ingress, durable receipt, and an idempotent Solid Queue
processor that writes the local subscription projection only after exact
provider refetch, checkout/provider-locator correlation, and tenant-scoped row
locking. No browser, checkout redirect, receipt alone, or outbound checkout API
result can create or change a subscription.

- `Billing::Subscription` is the local runtime projection of the provider
  subscription and references its `Plan` through `PlanPrice`. The verified
  writer resolves that price through the exact environment-qualified provider
  mapping before persistence.
- Catalog `PlanPrice` fields alone are not sufficient production mapping
  evidence because they have no test/live dimension. Checkout therefore
  requires an active `Billing::ProviderPriceMapping` for the configured
  environment and store; webhook projection uses the same exact boundary.
- Plan and price `active` flags stop new selection but do not revoke or rewrite
  an already synchronized subscription.
- The current subscription plus the canonical status/time matrix in
  [Billing Model](../billing_model.md#8-subscription-access-matrix) selects its
  paid plan when accessible. Otherwise the one active free plan is the
  effective plan; absence of that plan fails closed.
- `Plan.free` is an explicit system-managed fallback class, not a manual grant.
  It never changes subscription state and the database permits at most one
  active free plan.
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

Unknown/malformed paid-subscription status, variant, plan, environment,
timestamp, or conflicting projection fails closed for paid-plan selection; only
the explicit active free-plan fallback remains. Missing or malformed effective
plan/catalog entitlement input denies the applicable product or feature.
Catalog entitlement changes are reviewed, deployment-controlled local changes;
they never mutate subscription state or derive authority from a browser
redirect/provider command response.

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
- Status time bounds and the configurable past-due policy (15 days by default)
  require consistent clocks and deterministic boundary tests.
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

- Supporting manual or tenant-specific grants requires a separate, auditable
  local grant model and ADR; it must not overload subscription state or the
  single system free-plan fallback.
- Requiring immutable historical offerings would add plan versions and an
  explicit subscription/price migration rather than renaming a stable key.
- Extracting Billing requires a durable local projection with the same runtime
  contract.
- Provider migration requires dual-ingestion and explicit plan mapping; runtime
  remains local.
