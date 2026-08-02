# Billing Model: Lemon Squeezy

Status: Proposed
Last updated: 2026-07-16

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

### 1.1 Current implementation boundary

The repository currently contains the local Billing persistence foundation,
the outbound `Billing::LemonSqueezy::Client`, customer checkout initiation,
pending-return, fresh customer-portal retrieval, idempotent plan-change
commands, and the read-only
`Entitlements::SubscriptionAccessPolicy`/`Resolver`. The persistence layer
includes tenant-owned customers, checkout attempts, subscriptions, plan-change
commands, checkout-token provider locators, environment-qualified provider
price mappings, and the provider-wide webhook-event ledger.

An active organization `owner` or `billing` member can submit
`POST /o/:organization_slug/billing/checkouts`. The server resolves one active
`Billing::ProviderPriceMapping` for the configured test/live environment,
creates the tenant attempt and locator atomically, then performs exactly one
provider request outside the transaction. Lemon redirects to the canonical
local pending page. No checkout response or redirect writes a subscription.

The repository now exposes an isolated `POST /webhooks/lemon_squeezy`
controller, exact-body verifier, durable receipt service, Solid Queue handoff,
enqueue-recovery sweeper, and asynchronous subscription projector. The billing
overview, pending-return page, and platform-admin diagnostics read local state.
Checkout and browser redirects write only attempt/correlation state. A portal
click performs one fresh subscription retrieval and returns the validated
signed portal URL without persistence. A plan-change POST records a command and
performs one provider variant PATCH, but only a processor rooted in a verified
durable webhook receipt may write local customer or subscription state or mark
the command applied.

The entitlement resolver reads a current local subscription and never calls the
provider. The asynchronous projector consumes the exact environment/store/
product/variant mapping and is the only application writer of paid subscription
state. A checkout attempt, plan-change command, redirect, or successful Lemon
API response without a verified webhook root still cannot create or change
product access.

`Billing::Subscription#raw_payload` is a compatibility-oriented column name for
a bounded, recursively screened, explicitly allowlisted diagnostic snapshot. It
must never contain a raw webhook body, complete API response, authorization data,
signature, token, email/name, custom data, or signed checkout/portal URL. The
same minimal snapshot rule applies to `Billing::WebhookEvent`. Exact raw webhook
bytes exist only transiently for signature verification and are never persisted.
The ledger always has a unique content fingerprint and also accepts an optional
environment-qualified provider event ID with a unique index. Lemon currently
documents no delivery ID, so the fingerprint remains the required idempotency
identity rather than inventing provider authority.

Billing configuration reads the webhook signing secret separately from the API
key. The client reads its API key, store ID, environment, and checkout host from
explicit configuration, environment variables, or Rails credentials. It uses
a fixed HTTPS API origin and explicit connect/read timeouts, validates the exact
checkout store, variant, test mode, expiry, and HTTPS checkout URL host, and
maps provider, transport, JSON, and semantic-response failures to
provider-specific errors whose messages contain no response body or secret. It
performs one request per call and has no automatic retry middleware. Checkout
creation deliberately makes exactly one non-idempotent POST. Tests disable
non-local network access with WebMock so the suite cannot contact Lemon
Squeezy.

## 2. Billing invariants

1. Only active organization `owner` and `billing` memberships can view/manage
   tenant billing or start checkout. `admin` and `member` cannot. A separate
   `platform_admin` diagnostic view is read-only and confers no tenant billing
   mutation authority.
2. Every tenant billing query is scoped through `Current.organization`. The
   platform diagnostic must first resolve one exact submitted organization
   `public_id`, without loading a global organization dropdown, and then obey the
   same subscription child-query rule. Only the verified webhook resolver may
   query the global, non-authoritative `Billing::ProviderLocator` to select a
   candidate tenant.
3. The browser supplies a local plan-price ID only. Provider store, product,
   variant, price, custom price, environment, and redirect URL are server-owned.
4. Checkout correlation uses a short-lived signed `MessageVerifier` token whose
   payload contains the organization public ID, local plan-price ID, initiating
   user ID, high-entropy nonce, and expiry. The raw signed token exists only in
   memory and the provider custom field. PostgreSQL stores only the SHA-256
   digest of the nonce; email, name, slug, browser session, and client-supplied
   organization IDs are never correlation authority.
5. Checkout and provider command results create pending UI state only.
6. Exact raw-body signature verification precedes JSON parsing.
7. Verified delivery is durably recorded before HTTP 200.
8. Duplicate and out-of-order deliveries cannot regress or repeat state.
9. Unknown store, environment, variant, plan, status, or malformed data denies
   paid-plan selection and alerts when tenant/subscription correlation is safely
   resolved; only the explicit active free fallback may remain. When tenant
   resolution itself is untrusted, only a terminal event error is recorded and
   no tenant state is guessed.
10. Runtime authorization never calls Lemon Squeezy.
11. Test and live credentials/data/mappings are strictly separated; test data
    never grants access in production.

### 2.1 Customer billing and pricing shell

`GET /o/:organization_slug/billing` is available only to an active `owner` or
`billing` membership. It authorizes `Current.organization`, loads the current
subscription and command history only through tenant associations, and renders
its plan, interval/price, local status, lifecycle dates, payment-method summary,
effective-plan access, limit compatibility, and safe warnings. The GET performs
no Lemon API request. Portal and plan-change operations are separate authorized,
rate-limited POSTs. Their redirects and outbound provider results cannot change
what the runtime gate sees.

`POST /o/:organization_slug/billing/portal` revalidates the live membership and
current tenant subscription before and after the provider request. Each click
retrieves a fresh subscription resource and accepts only the expected
subscription/customer/store/environment plus an HTTPS signed portal URL on the
configured exact host. The controller emits a manual no-store/no-referrer 303;
the URL is never persisted or logged.

`POST /o/:organization_slug/billing/plan_changes` accepts only a local active
paid `PlanPrice`, resolves an exact active provider mapping, and invokes the
`Products::PlanCompatibility` query, which consumes the central immutable
Entitlements usage registry. It creates at most one open command per subscription
before sending one non-retried PATCH. A repeated request for the same target
returns the existing command; a different concurrent target is rejected.
Definitive provider rejection becomes `failed`; timeout, connection, rate-limit,
server, or malformed-success ambiguity becomes `creation_unknown` and retains
the unique open slot. Neither outcome changes the subscription.

`GET /o/:organization_slug/pricing` is a catalog comparison for any active
organization member. It shows active local plans and prices plus the locally
resolved effective plan. The GET remains local-only and cannot grant an
entitlement. For an eligible paid price with an active provider mapping in the
configured environment, an active owner or billing member sees a POST checkout
action; other members see an authorization-safe explanatory state. Test
mappings are labeled explicitly. Missing/inactive mappings and an existing
non-expired current subscription suppress checkout eligibility server-side as
well as in presentation.

`GET /o/:organization_slug/billing/checkouts/pending` is the sole checkout
return target. It authorizes the same owner/billing policy, reads the latest
attempt and current subscription only through `Current.organization`, and
shows local `creating`, `ready`, `creation_unknown`, failed, or terminal state.
It accepts no provider state as authority and offers an explicit refresh rather
than treating the redirect as completion.

### 2.2 Internal billing diagnostics

The `/admin` subscription index is a bounded support view, not a global
tenant-child query. A live platform administrator submits one exact organization
`public_id`; the application does not load a global organization dropdown.
`Current.organization` is set for that request, and subscription list/detail
records are loaded only through its association, with the index bounded to 100
rows per page. Safe presentation fields are the local/organization/plan/price
identifiers, provider and environment, provider subscription ID,
status/current/archive state, and lifecycle/provider timestamps. The controller
exposes no create, update, archive, replay, or delete action.

The failed-webhook view reads only `status = 'failed'` rows from the global
`Billing::WebhookEvent` ingress ledger, at most 100 rows per page. It may show
bounded operational identity, event/resource IDs, environment, timestamps,
attempt count, and `error_code`. It does not treat `quarantined` as `failed`, and
it does not infer a tenant for an unresolved row.

Neither view renders `raw_payload`, `pause`, `snapshot`, full record attributes,
credentials/configuration, authorization/signature data, checkout/portal URLs,
or unnecessary customer/payment metadata. In particular, an API key or webhook
secret is never loaded for presentation.

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

The webhook ingress accepts `subscription_created`, `subscription_updated`, and
`subscription_expired` subscription resources. It also accepts
`subscription_payment_success`, `subscription_payment_failed`, and
`subscription_payment_recovered` subscription-invoice resources. Lemon Squeezy
documents `subscription_updated` as the catch-all lifecycle event; the explicit
expiration and payment events provide prompt, idempotent refetch triggers. An
invoice payment status is never mapped directly to local subscription status or
authorization. Its allowlisted `subscription_id` only identifies the fixed
subscription endpoint whose current snapshot is validated by the processor.

These facts are not copied into authorization code. Provider DTO mapping and the
single local status matrix below isolate the application from provider details.

## 4. Catalog and environment mapping

`PlanPrice` is the local catalog/display record for a plan's monthly or yearly
price. Its complete Lemon store/product/variant tuple remains the immutable
provider identity source, but it has no environment dimension and is never used
alone to authorize checkout. `Billing::ProviderPriceMapping` binds that exact
tuple to one provider environment:

```text
provider + environment + store ID + product ID + variant ID
                                  -> exact local PlanPrice -> Plan
```

Rules:

- Checkout resolves exactly one active mapping by local price, provider, and
  configured `test` or `live` environment. The mapping tuple must match its
  `PlanPrice` tuple and the configured client store.
- Mapping identities are unique per local price/environment and per exact
  external tuple/environment. Provider IDs are immutable; catalog corrections
  use a new price/mapping instead of repointing history.
- Platform administrators configure mappings by choosing only the environment;
  provider IDs are copied from `PlanPrice`. Deactivation is supported, deletion
  and identifier editing are not.
- Only an active mapping whose `PlanPrice` and plan are active and paid is
  eligible for checkout. These checks are selection rules, not access grants.
- Inactive historical prices remain valid mappings for existing subscriptions;
  `active` is a checkout-selection flag, not an entitlement kill switch.
- An inactive plan remains referenced by an already synchronized subscription;
  deactivation is not an implicit subscription or entitlement transition.
- `LEMON_SQUEEZY_ENVIRONMENT` selects `test` or `live`; production defaults to
  `live` and non-production defaults to `test`, but deployments should set it
  explicitly. The client store ID and mapping store must match exactly.
- Provider identifiers are configuration/catalog data, not secrets, but they
  are still server-controlled and never trusted from a form.
- API keys and webhook secrets are credentials and remain outside the
  repository.
- A provider tuple already referenced by billing history is never silently
  repointed. Database unique/composite foreign keys connect checkout attempts
  to their exact mapping. The expand migration installs the checkout mapping FK
  as `NOT VALID`; a follow-up migration backfills compatible legacy rows as
  inactive mappings, rejects unsafe identities for remediation, and validates
  the FK before application rollout completes.
- An incoming variant with no exact active/historical mapping is recorded as a
  permanent projection failure and fails closed. It does not inherit a nearby
  plan by product name or price.
- The one active `Plan.free` row is the local runtime fallback when no paid
  subscription is accessible. It does not create a subscription, prove a
  payment, or permit tenant/manual grants.

## 5. Checkout sequence

### 5.1 Preconditions

`POST /o/:organization_slug/billing/checkouts` requires:

- authenticated enabled user;
- active `Current.membership` with role owner/billing;
- valid CSRF token;
- active local `PlanPrice` with an active plan and an exact server-owned mapping
  for the configured environment/store;
- no current non-terminal subscription;
- no pending checkout attempt.

Only verified local `expired` is terminal for replacement checkout. `unpaid`
denies product access but can still recover or transition at the provider, so it
does not permit a second subscription. `cancelled` remains non-terminal through
its paid grace period.

Under the organization billing lock, checkout creation first marks pending rows
expired when `now >= expires_at + 10 minutes`, then evaluates the static
one-pending-attempt unique constraint. This lazy transition is implemented; a
periodic sweeper remains future work and must perform the same idempotent
transition. Wall-clock expiry alone does not remove an index entry.

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
  LS-->>U: Redirect to /o/:slug/billing/checkouts/pending
  U->>A: GET canonical pending page
  A->>DB: Read local attempt/subscription
  A-->>U: Pending until verified webhook projection
```

Server request details:

- set one `enabled_variants` entry matching the environment-qualified mapping
  for the selected `PlanPrice`;
- set the canonical server-generated
  `/o/:organization_slug/billing/checkouts/pending` return URL for the current
  tenant, with no query, fragment, or userinfo; require HTTPS in production;
- set a short provider and local expiry, initially 30 minutes;
- generate a purpose- and expiry-scoped Rails `MessageVerifier` token carrying
  `organization_public_id`, `plan_price_id`, `user_id`, `nonce`, and
  `expires_at`; persist only `SHA256(nonce)` in the attempt and global provider
  locator, and put the transient signed token only in
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

Local configuration/request validation and provider statuses `400`, `401`,
`403`, `404`, and `422` are treated as definitive: the attempt becomes `failed`
and its locator becomes `definitive_creation_failure`. Timeout, connection
failure, `408`, `429`, any other non-allowlisted response, 5xx, malformed JSON,
or a semantically invalid success response are ambiguous and retain the one
pending slot as `creation_unknown`; the controller redirects to the pending
page with a safe do-not-retry message.

An orphan remote checkout is bounded by expiry and cannot grant access without
the correlated verified webhook.

The signed checkout context must be received and verified before its explicit
expiry. That durable event may be processed after local/provider checkout
expiry and may consume the retained attempt when the provider subscription's
`provider_created_at <= attempt.expires_at + 5 minutes` (clock-skew allowance).
A provider creation after that boundary is failed. If a valid event received in
time is processed after a newer local attempt exists, the organization billing
lock marks the unused newer attempt `superseded`. Two actually created
non-terminal provider subscriptions fail for operator cancellation/refund
rather than granting twice.

Expiry alone never resolves the checkout locator. This preserves delayed
verified correlation and is one reason user-facing organization archive is
deferred beyond the MVP.

### 5.4 Return behavior

The canonical return endpoint accepts no authoritative billing parameters. It
renders the latest tenant-scoped local `CheckoutAttempt` and `Subscription`
state and provides an ordinary manual refresh link. It never changes
subscription status, plan, entitlement, or completion based on query parameters
or provider JavaScript callbacks. The checkout controller redirects with a
manual 303 and does not persist or log the signed provider URL.

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
    Q->>DB: Load receipt ID; leave status received
    Note over Q,API: Future projection milestone
    Q-->>API: GET fixed /v1/subscriptions/:id
    API-->>Q: Current subscription snapshot
    Q-->>DB: Resolve tenant, lock, validate, project atomically
  end
```

### 6.1 Verification and durable receipt

The endpoint performs these bounded steps:

1. Enforce HTTPS at the proxy/application, POST, JSON content type, and a small
   request-body limit.
2. Read exact raw bytes once.
3. Require a valid 64-character hex `X-Signature`.
4. Calculate HMAC-SHA256 with the configured current signing secret and, during
   rotation, one distinct previous secret with an absolute expiry no more than
   seven days after process boot. Evaluate every eligible comparison before
   selecting a match. Production rejects partial, stale, malformed, duplicate,
   or excessive-overlap rotation configuration; previous-key use emits only a
   redacted request marker. No unbounded key list is accepted.
5. Parse JSON only after a valid signature.
6. Read signed-body `meta.event_name` as the only event-name authority. The
   unsigned `X-Event-Name` header is ignored for classification, so a missing or
   mismatched value cannot create a second receipt or change behavior.
7. Classify created/updated/expired events only with a valid `subscriptions`
   resource. Classify payment success/failed/recovered only with a valid
   `subscription-invoices` resource and bounded `attributes.subscription_id`.
   Other signed events are deterministic ignored receipts.
8. Validate the event-specific resource, configured store, and
   environment/test-mode shape. Signed invalid envelopes or configuration
   mismatches are quarantined, not projected. Invoice events are refetch
   triggers; their payment status is not subscription-state authority.
9. For every new signed receipt, calculate exact `SHA256(raw_body)` plus
   `SHA256(provider || configured_environment || raw_body)`. The untrusted,
   unsigned header is excluded from both identities; signed `meta.event_name`
   is stored separately when parsing succeeds.
10. If present, verify the purpose/expiry-scoped
    `meta.custom_data.checkout_attempt_token` (and accept the migration-safe
    `checkout_context` alias), validate its bounded payload, and calculate
    `SHA256(nonce)`. Retain only the digest and the verified organization public
    ID, local plan-price ID, initiating user ID, and expiry needed for the later
    cross-check. Never retain the nonce or raw signed token, and never hash the
    raw token as the lookup identity.
11. Insert `Billing::WebhookEvent` with the fingerprint and a minimal allowlisted
    envelope; never store raw body, signature, plaintext custom token, email,
    customer name, or signed URLs.
12. Enqueue only processable `received` rows after commit and return 200 after
    durable receipt.

A duplicate fingerprint is a successful no-op and returns 200. When an exact
legacy receipt has a null ingress marker, only a freshly HMAC-verified resend
with the same provider/environment/body digest may atomically stamp the current
marker, rebuild the screened envelope under the current allowlist, and re-enter
enqueue recovery; timestamps or synthetic rows cannot do so. A persistence
failure returns 503 so Lemon Squeezy retries. If enqueueing fails after receipt,
the periodic sweeper finds the durable `received` row; the endpoint can still
return 200 because local recovery no longer depends on provider redelivery.
The same sweeper redispatches rows that remain `received`, exceed the processing
lease, or hold a recoverable transient failure.

HTTP outcomes are explicit:

| Condition | Response | Durable behavior |
| --- | ---: | --- |
| invalid/missing signature | 401 | no ledger or tenant mutation |
| verified syntactically invalid JSON | 400 | no ledger or tenant mutation |
| ingress rate limit exceeded | 429 | no ledger; bounded `Retry-After` response |
| oversized body | 413 | no ledger or tenant mutation |
| unsupported content type | 415 | no ledger or tenant mutation |
| verified unsupported event | 200 | minimal `ignored` receipt, no enqueue |
| verified deterministic malformed/store/environment mismatch | 200 | minimal `quarantined` receipt and bounded warning, no projection |
| durable supported receipt or duplicate | 200 | enqueue once/recover via sweeper |
| transient database/internal persistence failure | 503 | no acknowledgement; provider retry expected |

Returning 200 for a verified deterministic mismatch avoids four futile
identical retries; the durable receipt and warning remain actionable. External
alert routing is a deployment follow-up. Error logs contain a request ID and
reason code, not headers/body.

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
8. Normalizes provider status and time fields. A first unknown or mismatched
   mapping leaves checkout authority unresolved, records a permanent redacted
   event failure, and creates no subscription row or paid grant. Unknown status
   for an existing subscription sets it to paid-fail-closed `unknown`/`invalid`.
   An unknown variant retains the last accepted mapping, advances the monotonic
   seen timestamp, and sets `sync_state = mapping_error`.
9. In one transaction, upserts the valid current subscription, creates/fills its
   subscription locator, consumes/completes the checkout attempt, applies the
   verified current price/status transition, and marks the event processed.
10. Clears `Current` in `ensure`.

Once correlation and an exact configured provider mapping are valid, tenant
usage is not a projection veto. The mapped provider plan is persisted even when
its finite limits are below current usage, and a matching open plan change is
marked applied in that projection transaction. The processor never deletes or
suspends product memberships, reports, or other tenant data to force
compatibility. Runtime derives any `over_limit` condition from the newly
effective plan and authoritative tenant rows.

The first subscription event cannot resolve by email/name. A missing or
mismatched token digest becomes a permanent redacted failure; an already
consumed locator is accepted only when it is bound to the same provider
subscription. A retained expired attempt is valid only when the event was
received before signed-context expiry and passes the provider-created-time rule
in section 5.3.

If the organization has a current expired subscription, a valid new correlated
subscription atomically supersedes the expired row and becomes current. A
second external subscription while the current row is non-terminal is
failed for admin remediation. Later verified events for a superseded
subscription may update its historical provider fields but cannot change
`archived_at`, restore `current`, or affect access.

## 7. Idempotency and event ordering

There are two independent guards:

1. **Delivery idempotency:** the unique content fingerprint collapses exact
   retries and manual resends with the same body. Signatures and request headers
   are excluded so secret rotation or a mutated unsigned event header cannot
   create a new identity.
2. **Projection idempotency:** the unique provider subscription ID, row lock,
   accepted `provider_updated_at`, and monotonic
   `last_seen_provider_updated_at` prevent repeated/invalid/older snapshots from
   regressing or re-enabling state.

Because the processor refetches the current subscription, distinct lifecycle
events normally converge on the newest provider state. Rules:

- `last_seen_provider_updated_at` records the newest verified snapshot even when
  its mapping is invalid; accepted projection time never moves backward;
- an older snapshot is marked `ignored` and changes no subscription data;
- the same timestamp and same critical snapshot is a no-op;
- the same timestamp with different status/variant/time fields is failed for
  admin review,
  sets a safely resolved local subscription `sync_state = invalid`, and triggers
  a refetch/alert;
- concurrent jobs serialize on the current subscription/organization billing
  rows;
- `past_due_started_at` is set from the validated `provider_updated_at` snapshot
  on entry into a past-due cycle, preserved through repeated past-due events,
  and cleared after leaving that status. A provider timestamp beyond the
  processor's bounded local clock-skew allowance is rejected rather than
  extending access.

### 7.1 Audit and lifecycle notification outbox

Every accepted semantic subscription transition, including renewal-date-only
updates, is recorded in the immutable tenant audit log inside the projection
transaction. A fail-closed projection change such as an unknown variant,
unknown status, invalid status timestamp, or provider-timestamp conflict is
also audited with a safe reason code. Provider-driven rows use a null actor and
retain only local plan/status identifiers, the verified webhook row ID,
environment/test-mode markers, and the processing job ID. Stale, duplicate,
and truly equal-semantic snapshots create neither audit nor notification rows;
fail-closed errors do not send lifecycle email.

Customer lifecycle email uses `Billing::LifecycleDelivery`, a primary-database
outbox created in that same transaction. One row is created for each currently
active, verified, enabled owner or billing member. The delivery job revalidates
that eligibility before sending, and otherwise marks the row discarded. A
unique source-event/kind/recipient key prevents webhook retry from producing
the same lifecycle message twice. Delivery jobs lock and lease a row, use a
stable message ID, cap retries, store only redacted failure codes, and are
recovered by a per-organization sweeper when queue handoff or a worker fails.

The delivery guarantee is at-least-once: a mail server can accept a message
immediately before a worker crash. The stable message ID helps downstream
deduplication, but true exactly-once email requires provider-side idempotency.
No email path can change subscription or entitlement state.

## 8. Subscription access matrix

This is the single canonical MVP paid-subscription predicate. Other documents
and code reference it rather than define alternatives. The resolver always
loads the candidate through `Current.organization.billing_subscriptions`, and
requires one current, non-archived row with a known `PlanPrice` and paid `Plan`.
The verified webhook projector additionally owns environment mapping,
provenance, and synchronization validation before it may persist that row.

| Local normalized status | Runtime billing decision | Time condition |
| --- | ---: | --- |
| no subscription | DENY paid; use free fallback | None |
| `on_trial` | ALLOW | Status is authoritative until a verified update changes it |
| `active` | ALLOW | None |
| `paused` | DENY paid; use free fallback | Immediate |
| `past_due` | ALLOW paid temporarily; then free fallback | `now < past_due_started_at + configured grace period` |
| `unpaid` | DENY paid; use free fallback | Immediate |
| `cancelled` | ALLOW paid; then free fallback | `now < ends_at`; missing timestamp denies paid |
| `expired` | DENY paid; use free fallback | Immediate |
| `unknown` or new provider value | DENY paid; use free fallback | Immediate |

The past-due window is an application policy, not a provider guarantee. It is
configured through `ENTITLEMENTS_PAST_DUE_GRACE_DAYS` (exposed internally as
`config.x.entitlements.past_due_grace_period`) and defaults to 15 days, slightly
exceeding the currently documented roughly two-week retry period while bounding
access if a terminal webhook is missed. The stored
`past_due_started_at` remains fixed through one cycle. Exact boundaries are
strict: access ends at, not after, the stored timestamp.

The additive database constraint is initially `NOT VALID` so existing rows are
not backfilled from a potentially later repeated provider update. New/changed
rows must carry a valid cycle start. A legacy past-due row with no start denies
paid access until verified re-synchronization; only then may operations validate
the constraint for all rows.

An accessible paid row returns its exact `Plan` through `PlanPrice`. When the
paid predicate denies or no current paid row exists, the resolver uses the one
`active: true, free: true` plan. If that row is absent, there is no effective
plan and product entitlement fails closed. The fallback never changes local
subscription state. Organization and billing administration remain available
according to organization roles.

`quarantined` is an ingress-envelope state, not a subscription state. If a
verified event safely resolves an existing subscription but projection input is
invalid, the event is marked `failed` and the subscription becomes
`mapping_error` or `invalid`, so runtime sees the denial. If tenant/subscription
resolution is untrusted or impossible, only a redacted event failure is stored
and no arbitrary subscription is changed.

## 9. Plan changes, cancellation, and portal

- `Billing::PlanChange` is a tenant-owned command-history record. It captures
  a targeted subscription, requested source/target `PlanPrice`, requesting
  membership, provider environment, state, timestamps, and a redacted failure
  code. The command revalidates active owner/billing authority, current synced
  subscription, source price, target price, and exact provider mapping under an
  organization lock. It is not an entitlement projection.
- Creating or marking a plan-change command submitted never edits the
  subscription's `plan_price_id`, status, or access decision. Only later
  verified-webhook projection may mark it applied and update the authoritative
  subscription in the same controlled workflow.
- Portal/API actions require owner/billing authorization and tenant scope.
- The application constructs requests with fixed provider origin and local
  subscription mapping.
- API success may set a separate checkout/command display state, but never edits
  local subscription status or plan.
- A variant change takes effect locally only after a verified
  `subscription_updated` webhook maps the exact variant to a `PlanPrice` and
  plan in the configured environment. The same projection transaction marks an
  exact open target `applied`; a verified different known target supersedes it,
  while an unchanged source variant leaves it open.
- Cancellation remains access-granting only before local `ends_at` according to
  the matrix.
- Resume, pause, recovery, and expiration are likewise synchronized from a
  verified event.
- Signed customer portal/payment URLs are fetched just in time after
  authorization, returned to the browser, and not persisted or logged.
- `Products::PlanCompatibility` consumes the central
  `Entitlements::Usage`/`LimitEnforcer` contract. Registered MVP usage is each
  product's `seat_limit`, measured from that product's active
  `Current.organization.product_memberships`, and Analytics `report_limit`,
  measured from `Current.organization.analytics_reports`. Exact finite capacity
  and unlimited are allowed; a missing/disabled target limit is zero capacity;
  an enabled unregistered limit fails closed.
- An application-originated incompatible target is blocked before PATCH. Each
  overage reports only the minimum newest candidates required to reach the
  target, ordered by `created_at DESC, id DESC`, so the billing UI can explain a
  deterministic remediation path. Preflight never deletes or changes those
  records.
- A verified external/provider-portal downgrade to a known mapped variant is
  always projected and any matching command is applied; it is not rejected to
  preserve the old plan. Derived over-limit warnings then block only new
  consuming/increasing operations. Existing product rows, reads, non-consuming
  operations, and actions that release capacity remain available.

Payment success/failure/recovery events are accepted only as signals to refetch
and project the associated current subscription resource. Invoice status never
independently changes entitlement. Refund history and invoice UI remain outside
the authorization MVP; the synchronized subscription snapshot remains the only
billing input.

## 10. Retry, quarantine, and reconciliation

### 10.1 Retryable processing failures

Retry with exponential backoff and jitter:

- timeouts and connection failures;
- API 429 using provider rate-limit guidance;
- provider 5xx;
- provider 404 for a short bounded propagation window;
- transient database deadlocks.

Processing is capped at eight successful claims. The worker records transient
failures for retry, the sweeper only re-enqueues rows below that bound, and a
stale eighth claim becomes the terminal redacted `retry_exhausted` failure.

### 10.2 Permanent projection failure

Record a redacted terminal failure and alert without granting access:

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
- A separate periodic job enumerates organization roots and re-enqueues due or
  abandoned lifecycle-delivery rows only through
  `Current.organization.billing_lifecycle_deliveries`.
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
- Inactive plan/price, absent environment-qualified mapping, and client-supplied
  provider fields/custom price/redirect fail.
- The request contains exactly one allowlisted variant and a transient opaque
  token; only its digest exists in the database/log capture.
- A non-terminal current subscription and concurrent pending attempt block
  another checkout; an expired current subscription permits replacement.
- Lazy and swept expiry release the pending unique slot only after the ten-minute
  delivery grace.
- A webhook received before context expiry may process after attempt expiry only
  when provider creation was within the five-minute skew boundary; expired
  context, post-boundary creation, resolved token, and competing old/new attempts
  follow the documented rules. Expiry alone leaves the locator unresolved.
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
  `meta.event_name`.
- Verified unsupported event and deterministic malformed/store/environment
  mismatch persist minimal ignored/quarantined receipts and return 200 without
  projection.
- The configured current secret works and missing configuration fails closed;
  a distinct previous secret works only before its strict bounded expiry, and
  current/previous signatures over the same body remain one receipt.
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
- Network 429/timeouts/5xx retry; permanent failures remain visible in the
  failed-webhook admin view.
- Unknown status or variant fails closed for paid-plan selection instead of
  retaining a prior paid grant; only the active free fallback may remain.
- Equal snapshots are no-ops; altered equal-timestamp data fails closed.
- One attempt cannot create two subscriptions; one organization cannot have two
  current subscriptions.
- A new subscription atomically supersedes only an expired current row; a
  second non-terminal subscription fails for admin remediation, and later
  events cannot reactivate an archived row.
- Plan changes take effect only from verified-webhook processing.

### 11.4 Matrix and runtime

Table-driven tests cover every row, free fallback, exact cancellation boundary,
and configurable past-due boundary, including missing timestamps and repeated
past-due cycles. Recovery to active and later new past-due cycles reset time
correctly.

Authorization tests assert zero provider HTTP requests.

### 11.5 Outbound adapter

- WebMock disables all non-local network access for the entire test process;
  every Lemon response is explicit synthetic JSON.
- Tests cover the fixed HTTPS origin, authorization/JSON:API headers, explicit
  connect/read timeouts, configuration precedence, successful JSON/empty
  response handling, and bounded response size.
- Separate cases cover 4xx, authentication, not-found, rate-limit, 5xx,
  timeout, connection failure, redirect, and invalid JSON mapping without
  exposing API keys or provider bodies.
- A non-idempotent request test asserts exactly one network attempt; retry policy
  remains operation-specific and outside the low-level client.
- Adapter tests assert zero `Billing::Subscription` mutations.

### 11.6 Provider contract verification

In a non-production test environment, manually exercise Lemon Squeezy test-mode
checkout, redirect-before-webhook, webhook simulation/resend, duplicate,
cancel/resume/pause/expire, plan change, and live/test separation. Sanitized
fixtures derived from those payloads become automated contract tests.

Webhook configuration subscribes to `subscription_created`,
`subscription_updated`, `subscription_expired`,
`subscription_payment_success`, `subscription_payment_failed`, and
`subscription_payment_recovered`. Lifecycle drills verify that invoice events
only trigger a fixed subscription refetch and that the normalized subscription
snapshot—not the invoice status—drives projection.

### 11.7 Internal diagnostic views

- Ordinary users and organization owners without `platform_admin` receive no
  subscription or webhook-event list/detail response.
- Subscription requests require one exact allowed organization `public_id`, do
  not load a global organization dropdown, and instrument SQL to prove child
  rows load through `Current.organization`; a guessed subscription from another
  organization is absent.
- Index/detail responses are read-only and omit `raw_payload`, `pause`,
  `snapshot`, credentials, signatures, and secret-bearing configuration.
- The webhook collection contains failed rows only; processed, ignored,
  quarantined, received, and processing rows remain absent.
- Subscription and failed-webhook indexes return at most 100 rows per page.

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
