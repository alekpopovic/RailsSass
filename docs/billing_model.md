# Billing Model: Lemon Squeezy

Status: Proposed
Last updated: 2026-07-15

## 1. Purpose and authority

This document defines checkout, webhook synchronization, subscription access
policy, failure handling, and provider boundaries for the MVP.

The local PostgreSQL `Billing::Subscription` projection is the only runtime
billing input to authorization. Lemon Squeezy is authoritative for commercial
subscription lifecycle, but application access changes only when processing is
rooted in a verified, durably stored webhook. A redirect, portal visit, checkout
API response, subscription command response, or standalone reconciliation API
call never changes local subscription state.

Related documents:

- [Data Model](data_model.md#8-billing)
- [Authorization Model](authorization_model.md)
- [Security Model](security_model.md)
- [ADR 0002: Local Entitlements](adr/0002-local-entitlements.md)

## 2. Billing invariants

1. Only active organization `owner` and `billing` memberships can view/manage
   billing or start checkout. `admin` and `member` cannot.
2. Every tenant billing query is scoped through `Current.organization`. Only the
   verified webhook resolver may query the global, non-authoritative
   `Billing::ProviderLocator` to select a candidate tenant.
3. The browser supplies a local billing-price ID only. Provider store, product,
   variant, price, custom price, environment, and redirect URL are server-owned.
4. Checkout correlation uses a transient high-entropy local token. Only its
   SHA-256 digest is persisted; email, name, slug, browser session, and
   client-supplied organization IDs are never correlation authority.
5. Checkout and provider command results create pending UI state only.
6. Exact raw-body signature verification precedes JSON parsing.
7. Verified delivery is durably recorded before HTTP 200.
8. Duplicate and out-of-order deliveries cannot regress or repeat state.
9. Unknown store, environment, variant, plan, status, or malformed data denies
   access and alerts when tenant/subscription correlation is safely resolved;
   when tenant resolution itself is untrusted, only the event is quarantined and
   no tenant state is guessed.
10. Runtime authorization never calls Lemon Squeezy.
11. Test and live credentials/data/mappings are strictly separated; test data
    never grants access in production.

## 3. Current provider contract

The following are provider facts verified against official Lemon Squeezy
documentation on 2026-07-15:

- Webhooks are JSON `POST` requests with `X-Event-Name` and `X-Signature`
  headers. `X-Signature` is a hex HMAC-SHA256 digest of the exact raw request
  body using the configured signing secret.
- Lemon Squeezy expects HTTP 200. Non-200 delivery is retried up to three more
  times with exponential backoff; automatic retries then stop, although recent
  events can be resent manually.
- The documented webhook envelope does not include a unique delivery/event ID.
  `data.id` identifies the provider resource, not a particular delivery.
- Checkout `checkout_data.custom` is returned as `meta.custom_data` in related
  subscription webhooks.
- Subscription statuses are `on_trial`, `active`, `paused`, `past_due`,
  `unpaid`, `cancelled`, and `expired`.
- `cancelled` remains in a paid grace period until `ends_at`; `expired` has
  ended. Lemon Squeezy documents approximately four payment retries over two
  weeks before `unpaid`, while the application must choose its own unpaid
  access policy.
- Test and live API keys, products, and webhooks are separate, and subscription
  payloads contain `test_mode`.
- Provider API calls have a documented 300-request-per-minute limit.

The MVP registers exactly `subscription_created` and `subscription_updated`.
This deliberately relies on Lemon Squeezy's current documentation that
`subscription_updated` is the catch-all subscription lifecycle event; lifecycle
contract tests consume the accompanying updated payload. Granular lifecycle and
payment events are not registered for authorization.

These facts are not copied into authorization code. Provider DTO mapping and the
single local status matrix below isolate the application from provider details.

## 4. Catalog and environment mapping

`Billing::Price` is the only allowed mapping from a Lemon Squeezy variant to a
local plan version. It binds:

```text
provider + environment + store ID + product ID + variant ID
                                  -> exact immutable Plan version
```

Rules:

- Only an active price whose immutable plan is still `published` may be selected
  for a new checkout. This plan-state recheck, not eventual price cleanup, is
  the sales-stop boundary.
- Inactive historical prices remain valid mappings for existing subscriptions;
  `active` is a checkout-selection flag, not an entitlement kill switch.
- A retired plan remains valid for an already synchronized subscription; plan
  retirement is a sales lifecycle transition, not an implicit customer revoke.
- Production checkout selects a `live` mapping; development/test uses `test`.
- Provider identifiers are configuration/catalog data, not secrets, but they
  are still server-controlled and never trusted from a form.
- API keys and webhook secrets are credentials and remain outside the
  repository.
- Published plan versions are immutable. A new entitlement version requires a
  new provider variant or an explicit subscription migration; an existing used
  price is never silently repointed.
- An incoming variant with no exact active/historical mapping is quarantined and
  fail-closed. It does not inherit a nearby plan by product name or price.

## 5. Checkout sequence

### 5.1 Preconditions

`POST /o/:organization_slug/billing/checkouts` requires:

- authenticated enabled user;
- active `Current.membership` with role owner/billing;
- valid CSRF token;
- active local billing price in the correct environment whose plan is still
  `published`;
- no current non-terminal subscription;
- no pending checkout attempt.

Only verified local `expired` is terminal for replacement checkout. `unpaid`
denies product access but can still recover or transition at the provider, so it
does not permit a second subscription. `cancelled` remains non-terminal through
its paid grace period.

Under the organization billing lock, checkout creation first marks pending rows
expired when `now >= expires_at + 10 minutes`, then evaluates the static
one-pending-attempt unique constraint. A periodic sweeper performs the same
idempotent transition. Wall-clock expiry alone does not remove an index entry.

Existing subscribers use a server-authorized provider portal/subscription
command rather than opening a second subscription checkout.

### 5.2 Sequence

```mermaid
sequenceDiagram
  participant U as Browser
  participant A as Rails
  participant DB as PostgreSQL
  participant LS as Lemon Squeezy

  U->>A: POST /o/:slug/billing/checkouts (local price ID)
  A->>A: Authenticate, establish tenant, authorize owner/billing
  A->>DB: Lock billing state; create attempt + digest locator
  A->>LS: Create checkout with allowlisted variant and opaque token
  LS-->>A: Checkout ID, URL, expiry
  A->>DB: Validate and mark attempt ready
  A-->>U: 303 redirect to provider URL
  U->>LS: Complete or abandon checkout
  LS-->>U: Redirect to /o/:slug/billing
  U->>A: GET billing page
  A->>DB: Read local attempt/subscription
  A-->>U: Pending until verified webhook projection
```

Server request details:

- set one `enabled_variants` entry matching `Billing::Price`;
- set a canonical server-generated return URL for the current tenant;
- set a short provider and local expiry, initially 30 minutes;
- generate a high-entropy token, persist only its SHA-256 digest in the attempt
  and global provider locator, and put the transient plaintext token only in
  `checkout_data.custom.checkout_attempt_token`;
- optionally prefill the authenticated user's email, but never use it later for
  tenant resolution;
- disallow custom price and all client-selected provider fields.

Validate the provider response's store, variant, environment, checkout ID, URL
origin, and expiry before marking the attempt `ready`.

### 5.3 Ambiguous checkout creation

The current official checkout documentation does not describe an idempotency
key. Checkout creation is serialized per organization. Any outcome after the
request may have reached Lemon Squeezy that does not prove non-creation is
ambiguous: timeout, connection reset, 5xx, truncated/malformed response, or a
2xx response that fails critical ID/origin/mapping validation. In each case:

- set the attempt to `creation_unknown`;
- do not grant access;
- do not blindly create another checkout;
- allow an operator/user retry only after the local expiry plus ten-minute
  delivery grace. A definitive provider rejection proving no checkout was
  created may resolve the locator and fail the attempt earlier; a timeout may
  not.

Only a failure before request transmission or a documented deterministic
provider rejection that proves no checkout was created may set `failed` and
resolve correlation as `definitive_creation_failure`.

An orphan remote checkout is bounded by expiry and cannot grant access without
the correlated verified webhook.

A verified subscription webhook may arrive after local/provider checkout expiry.
It may consume an unresolved retained attempt when the provider subscription's
`provider_created_at <= attempt.expires_at + 5 minutes` (clock-skew allowance),
regardless of processing time. A provider creation after that boundary is
quarantined. If a delayed valid old attempt competes with a newer attempt, the
organization billing lock chooses the provider-created subscription that
predates the newer attempt and marks the unused newer local attempt
`superseded`; two actually created non-terminal provider subscriptions are
quarantined for operator cancellation/refund rather than granting twice.

Expiry alone never resolves the checkout locator. This preserves delayed
verified correlation and is one reason user-facing organization archive is
deferred beyond the MVP.

### 5.4 Return behavior

The return endpoint accepts no authoritative billing parameters. It renders the
latest local `CheckoutAttempt` and `Subscription` state and may refresh/poll via
Turbo. It never changes subscription status, plan, entitlement, or completion
based on query parameters or provider JavaScript callbacks.

## 6. Webhook receipt sequence

The global endpoint is `POST /webhooks/lemon_squeezy`. It has no user session
requirement. CSRF exemption applies only to this endpoint.

```mermaid
sequenceDiagram
  participant LS as Lemon Squeezy
  participant W as Webhook endpoint
  participant DB as PostgreSQL
  participant Q as Solid Queue
  participant API as Lemon API

  LS->>W: Signed raw POST
  W->>W: Size limit; HMAC raw body; validate envelope
  W->>DB: Insert verified event by unique fingerprint
  alt duplicate
    DB-->>W: Unique conflict / existing receipt
    W-->>LS: 200
  else persisted
    W->>Q: Enqueue after commit
    W-->>LS: 200
    Q->>API: GET fixed /v1/subscriptions/:id
    API-->>Q: Current subscription snapshot
    Q->>DB: Resolve tenant, lock, validate, project atomically
  end
```

### 6.1 Verification and durable receipt

The endpoint performs these bounded steps:

1. Enforce HTTPS at the proxy/application, POST, JSON content type, and a small
   request-body limit.
2. Read exact raw bytes once.
3. Require a valid 64-character hex `X-Signature`.
4. Calculate HMAC-SHA256 with the configured current signing secret and compare
   in constant time. During bounded rotation, also permit the previous secret
   and record its key version.
5. Parse JSON only after a valid signature.
6. Read signed-body `meta.event_name` as the only event-name authority. Compare
   `X-Event-Name` only as advisory provider-contract telemetry; a missing or
   mismatched unsigned header cannot change classification.
7. Classify only `subscription_created` and `subscription_updated` with a valid
   subscription resource as processable; other signed events are deterministic
   ignored receipts.
8. Validate configured store and environment/test-mode shape. Signed malformed
   or configuration-mismatched events are quarantined, not projected.
9. Calculate
   `SHA256(provider || configured_environment || raw_body)`. The untrusted,
   unsigned header is excluded; signed `meta.event_name` is stored separately
   when parsing succeeds.
10. If present, hash allowlisted
    `meta.custom_data.checkout_attempt_token` immediately and retain only its
    digest.
11. Insert `Billing::WebhookEvent` with the fingerprint and a minimal allowlisted
    envelope; never store raw body, signature, plaintext custom token, email,
    customer name, or signed URLs.
12. Enqueue only processable `received` rows after commit and return 200 after
    durable receipt.

A duplicate fingerprint is a successful no-op and returns 200. A persistence
failure returns 503 so Lemon Squeezy retries. If enqueueing fails after receipt,
the periodic sweeper finds the durable `received` row; the endpoint can still
return 200 because local recovery no longer depends on provider redelivery.

HTTP outcomes are explicit:

| Condition | Response | Durable behavior |
| --- | ---: | --- |
| invalid/missing signature | 401 | no ledger or tenant mutation |
| ingress rate limit exceeded | 429 | no ledger; bounded `Retry-After` response |
| oversized body | 413 | no ledger or tenant mutation |
| unsupported content type | 415 | no ledger or tenant mutation |
| verified unsupported event | 200 | minimal `ignored` receipt, no enqueue |
| verified deterministic malformed/store/environment mismatch | 200 | minimal `quarantined` receipt and alert, no projection |
| durable supported receipt or duplicate | 200 | enqueue once/recover via sweeper |
| transient database/internal persistence failure | 503 | no acknowledgement; provider retry expected |

Returning 200 for a verified deterministic mismatch avoids four futile
identical retries; the durable alert remains actionable. Error logs contain a
request ID and reason code, not headers/body.

### 6.2 Processing

The asynchronous processor:

1. Claims the event idempotently and increments its attempt count.
2. Builds a fixed Lemon Squeezy API URL from the validated subscription resource
   ID; it never follows payload relationship URLs.
3. Fetches the current provider subscription snapshot. This work is permitted
   to mutate local state only because it is rooted in the verified event.
4. Validates API response type, resource ID, store, environment, `test_mode`,
   and bounded provider fields; exact variant mapping is evaluated only after
   trusted tenant/token correlation.
5. Resolves a candidate organization only through the global
   `Billing::ProviderLocator`, using either the existing provider/environment
   subscription ID or the verified event's checkout-token digest.
6. Sets `Current.organization`, then reloads the checkout attempt/subscription
   through it and locks the relevant rows.
7. Cross-checks organization, origin/current price mapping, plan, store,
   product, variant, token digest, provider-created time, existing subscription,
   and one-current-subscription invariants.
8. Normalizes provider status and time fields. Once the base token/tenant/store/
   environment/time correlation is trusted, a first unknown mapping consumes
   the checkout locator and creates an unresolved subscription locator so the
   token cannot be reused and a controlled replay can recover. It creates no
   subscription row or grant. Unknown status or malformed input
   sets a safely resolved existing subscription to fail-closed `unknown`/`invalid`.
   An unknown variant retains the last accepted mapping and sets
   `sync_state = mapping_error`; the unknown snapshot stays in the filtered
   event. A first invalid/unmapped subscription creates no subscription grant.
9. In one transaction, upserts the valid current subscription, creates/fills its
   subscription locator, consumes/completes the checkout attempt, applies the
   verified current price/status transition, and marks the event processed.
10. Clears `Current` in `ensure`.

The first subscription event cannot resolve by email/name. A missing,
already-consumed, or mismatched token digest is quarantined. A retained expired
attempt is valid only under the provider-created-time rule in section 5.3.

If the organization has a current expired subscription, a valid new correlated
subscription atomically supersedes the expired row and becomes current. A
second external subscription while the current row is non-terminal is
quarantined. Later verified events for a superseded subscription may update its
historical provider fields but cannot clear `superseded_at` or affect access.

## 7. Idempotency and event ordering

There are two independent guards:

1. **Delivery idempotency:** the unique content fingerprint collapses exact
   retries and manual resends with the same body. Signatures and request headers
   are excluded so secret rotation or a mutated unsigned event header cannot
   create a new identity.
2. **Projection idempotency:** the unique external subscription ID, row lock,
   accepted `provider_updated_at`, and monotonic
   `last_seen_provider_updated_at` prevent repeated/invalid/older snapshots from
   regressing or re-enabling state.

Because the processor refetches the current subscription, distinct lifecycle
events normally converge on the newest provider state. Rules:

- `last_seen_provider_updated_at` records the newest verified snapshot even when
  its mapping is invalid; accepted projection time never moves backward;
- an older snapshot is marked `ignored` and changes no subscription data;
- the same timestamp and same critical snapshot is a no-op;
- after a catalog/code repair, an explicitly requested replay may re-evaluate
  that same verified snapshot when the local subscription is fail-closed or no
  subscription was created; it may recover only if the stored fingerprint and
  critical fields match and every mapping now validates;
- the same timestamp with different status/variant/time fields is quarantined,
  sets a safely resolved local subscription `sync_state = invalid`, and triggers
  a refetch/alert;
- concurrent jobs serialize on the current subscription/organization billing
  rows;
- `past_due_started_at` is set from the validated `provider_updated_at` snapshot
  on entry into a past-due cycle, preserved through repeated past-due events,
  and cleared after leaving that status. A provider timestamp more than five
  minutes after local `received_at` is invalid/quarantined rather than extending
  access.

## 8. Subscription access matrix

This is the single canonical MVP billing predicate. Other documents and code
reference it rather than define alternatives.

Every `ALLOW` also requires all preconditions:

- one current, non-superseded local subscription;
- `sync_state = synced`;
- correct application environment and test/live mapping;
- exact known billing price and immutable plan mapping;
- no mapping conflict or invalid provider snapshot;
- tenant-scoped lookup through `Current.organization`.

| Local normalized status | Runtime billing decision | Time condition |
| --- | ---: | --- |
| no subscription | DENY | None |
| `on_trial` | ALLOW | `now < trial_ends_at`; missing timestamp is invalid/deny |
| `active` | ALLOW | None |
| `paused` | ALLOW | Explicit MVP policy: payment collection pause is not product suspension |
| `past_due` | ALLOW temporarily | `now < past_due_started_at + 15 days` |
| `unpaid` | DENY | Immediate |
| `cancelled` | ALLOW | `now < ends_at`; missing timestamp is invalid/deny |
| `expired` | DENY | Immediate |
| `unknown` or new provider value | DENY | Immediate |
| any `sync_state` other than `synced` | DENY | Immediate |

The 15-day past-due window is an application policy, not a provider guarantee.
It slightly exceeds the currently documented roughly two-week retry period while
bounding access if a terminal webhook is missed. Exact boundaries are strict:
access ends at, not after, the stored timestamp.

This predicate returns an exact `Plan` only when allowed. With no allowed
subscription there is no free/manual fallback plan in the MVP. Organization and
billing administration remain available according to organization roles, while
product access denies.

`quarantined` is a webhook-event processing state, not a subscription state. If
a verified invalid event safely resolves an existing subscription, projection
sets that subscription to `mapping_error` or `invalid`, so runtime sees the
denial. If tenant/subscription resolution itself is untrusted or impossible,
only the event is quarantined and no arbitrary subscription is changed.

## 9. Plan changes, cancellation, and portal

- Portal/API actions require owner/billing authorization and tenant scope.
- The application constructs requests with fixed provider origin and local
  subscription mapping.
- API success may set a separate checkout/command display state, but never edits
  local subscription status or plan.
- A variant change takes effect locally only after a verified
  `subscription_updated` webhook maps the exact variant to a plan version.
- Cancellation remains access-granting only before local `ends_at` according to
  the matrix.
- Resume, pause, recovery, and expiration are likewise synchronized from a
  verified event.
- Signed customer portal/payment URLs are fetched just in time after
  authorization, returned to the browser, and not persisted or logged.

Payment success/failure/refund events are outside the authorization MVP. They
may be added later for audit/UI, but they never independently change entitlement;
the synchronized subscription snapshot remains the only billing input.

## 10. Retry, quarantine, and reconciliation

### 10.1 Retryable processing failures

Retry with exponential backoff and jitter:

- timeouts and connection failures;
- API 429 using provider rate-limit guidance;
- provider 5xx;
- provider 404 for a short bounded propagation window;
- transient database deadlocks.

### 10.2 Permanent quarantine

Quarantine and alert without granting access:

- authentication/configuration failure;
- wrong store or environment/test mode;
- unknown variant/plan/status;
- malformed resource or critical timestamp;
- token/organization/subscription mismatch;
- conflicting equal-timestamp snapshot;
- an attempt to create a second current subscription.

Store only redacted reason codes. Operators inspect provider dashboards and
application IDs, not raw PII in logs.

### 10.3 Sweep and reconciliation

- A checkout-attempt scheduler runs at least every five minutes, enumerates only
  organization roots, and enqueues per-organization sweepers that perform the
  same tenant-scoped `expires_at + 10 minutes` locked expiry transition as
  checkout creation.
- A periodic Solid Queue job re-enqueues aged `received` and recoverable
  `processing`/`failed` events.
- Alerts fire on oldest-event age, retry exhaustion, quarantine, and subscription
  sync conflicts.
- A read-only reconciliation job may compare current provider/local state and
  report drift at least every six hours. First detected drift alerts the on-call;
  the launch SLO is acknowledgement within 30 minutes and provider resend or
  verified-event replay within four hours.
- Reconciliation never writes subscription state by itself. Repair requests a
  provider webhook resend or reprocesses an already verified local event, so
  every state mutation retains a verified-webhook root.

An entirely missed terminal webhook can otherwise leave a locally `active`
subscription access-granting indefinitely; there is intentionally no active
freshness cutoff because annual subscriptions may have no frequent lifecycle
event. The reconciliation SLO, dashboard resend, alerts, and launch drill bound
this accepted operational risk without creating a second mutation authority.

## 11. Test strategy

### 11.1 Checkout

- Owner/billing allowed; admin/member/non-member denied server-side.
- CSRF is enforced.
- Cross-tenant slug/price/attempt IDs cannot select another tenant.
- Inactive price and client-supplied provider fields/custom price/redirect fail.
- The request contains exactly one allowlisted variant and a transient opaque
  token; only its digest exists in the database/log capture.
- A non-terminal current subscription and concurrent pending attempt block
  another checkout; an expired current subscription permits replacement.
- Lazy and swept expiry release the pending unique slot only after the ten-minute
  delivery grace.
- A webhook processed after attempt expiry succeeds only when provider creation
  was within the five-minute skew boundary; post-expiry creation, resolved token,
  and competing old/new attempts follow the documented rules. Expiry alone
  leaves the locator unresolved.
- Timeout/reset/5xx/malformed or invalid-success responses remain
  `creation_unknown`; definitive no-create failures may become `failed`.
- Provider API success, checkout completion, and return redirect never change
  subscription or entitlement.
- Return page remains pending until webhook processing completes.

### 11.2 Webhook ingress

- Official-style sanitized fixture with exact signature succeeds.
- One-byte body mutation, missing/malformed signature, and wrong key return 401
  without persistence; rate limit returns 429, oversized returns 413, and wrong
  content type returns 415.
- Replaying one signed body with a mutated `X-Event-Name` header cannot create a
  second fingerprint/receipt or alter classification. A first delivery with a
  missing/mismatched header is still classified only by signed
  `meta.event_name`, while emitting bounded anomaly telemetry.
- Verified unsupported event and deterministic malformed/store/environment
  mismatch persist minimal ignored/quarantined receipts and return 200 without
  projection.
- Current and bounded previous secret work during rotation; expired prior key
  fails.
- Duplicate delivery returns 200 and stores/processes once.
- Database failure returns 503; durable receipt with enqueue failure is recovered
  by the sweeper.
- Logs contain neither payload nor secret material.
- First-subscription custom data is reduced to a digest; raw/plaintext token is
  absent while later resolution remains possible.

### 11.3 Projection

- First creation maps only through the matching unresolved token digest in the
  global provider locator, then reloads through `Current.organization`.
- Store/environment/variant/plan/token mismatch cannot attach a tenant.
- All tenant mutation after resolution is scoped through
  `Current.organization`.
- Older/equal-conflicting/concurrent events follow section 7.
- Network 429/timeouts/5xx retry; permanent failures quarantine.
- Unknown status or variant fails closed instead of retaining a prior grant.
- A controlled replay of the same verified snapshot can recover after a
  mapping/code repair, but altered equal-timestamp data remains quarantined.
- One attempt cannot create two subscriptions; one organization cannot have two
  current subscriptions.
- A new subscription atomically supersedes only an expired current row; a
  second non-terminal subscription quarantines, and later events cannot
  reactivate a superseded row.
- Plan changes take effect only from verified-webhook processing.

### 11.4 Matrix and runtime

Table-driven tests cover every row and exact trial, cancellation, and 15-day
past-due boundary, including missing timestamps and repeated past-due cycles.
Recovery to active and later new past-due cycles reset time correctly.

Authorization tests assert zero provider HTTP requests.

### 11.5 Provider contract verification

In a non-production test environment, manually exercise Lemon Squeezy test-mode
checkout, redirect-before-webhook, webhook simulation/resend, duplicate,
cancel/resume/pause/expire, plan change, and live/test separation. Sanitized
fixtures derived from those payloads become automated contract tests.

Webhook configuration subscribes exactly to `subscription_created` and
`subscription_updated`; lifecycle drills verify the accompanying catch-all
updated event drives projection rather than relying on an unregistered granular
event.

## 12. Monitoring and operational acceptance

Production billing is ready only when:

- webhook endpoint is HTTPS and configured separately for live mode;
- current/previous secret rotation is documented and tested;
- queue worker and receipt sweeper are continuously running;
- duplicate, latency, failure, quarantine, and drift alerts reach an owner;
- provider dashboard resend plus local verified-event replay runbooks exist;
- a checkout redirect-before-webhook drill proves no access change;
- duplicate and reordered event drills converge correctly;
- test-mode records cannot grant production access.

## 13. Official references

- [Signing Requests](https://docs.lemonsqueezy.com/help/webhooks/signing-requests)
- [Webhook Requests](https://docs.lemonsqueezy.com/help/webhooks/webhook-requests)
- [Webhook Event Types](https://docs.lemonsqueezy.com/help/webhooks/event-types)
- [Sync With Webhooks](https://docs.lemonsqueezy.com/guides/developer-guide/webhooks)
- [Create a Checkout](https://docs.lemonsqueezy.com/api/checkouts/create-checkout)
- [Checkout Object](https://docs.lemonsqueezy.com/api/checkouts/the-checkout-object)
- [Passing Custom Data](https://docs.lemonsqueezy.com/help/checkout/passing-custom-data)
- [Subscription Object](https://docs.lemonsqueezy.com/api/subscriptions/the-subscription-object)
- [Managing Subscriptions](https://docs.lemonsqueezy.com/guides/developer-guide/managing-subscriptions)
- [API Reference](https://docs.lemonsqueezy.com/api)
