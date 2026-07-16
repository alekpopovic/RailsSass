# Security Model

Status: Proposed
Last updated: 2026-07-16

## 1. Purpose

This document defines assets, trust boundaries, threats, required controls,
security tests, and accepted MVP limitations. It applies to the architecture in
[Architecture](architecture.md), the tenant/RBAC contract in
[Authorization Model](authorization_model.md), and Lemon Squeezy integration in
[Billing Model](billing_model.md).

Security controls are server-side and database-backed. Presentation behavior is
not a control.

## 2. Security objectives

1. Prevent one organization from reading or modifying another organization's
   data.
2. Prevent users from exercising organization or product capabilities they were
   not granted.
3. Prevent forged, replayed, reordered, or confused billing messages from
   over-granting plan access.
4. Protect credentials, authentication tokens, invitation/reset/verification
   tokens, provider URLs, and sensitive customer data from disclosure.
5. Preserve authorization integrity during concurrency, retries, deployment,
   and partial failure.
6. Keep production recoverable through backups, observable queues, and bounded
   incident response.

## 3. Assets and data classification

| Class | Examples | Required handling |
| --- | --- | --- |
| Secret | Rails master key, database password/URL, Lemon API keys, webhook secrets, mail credentials | Secret manager/Kamal environment only; never repository, logs, browser, fixtures, or docs |
| Authentication token | Session, password-reset, email-verification, invitation token | Opaque tokens are high entropy and one-way digested at rest; Rails signed account tokens are purpose/expiry/state bound; never log |
| Sensitive signed URL | Checkout URL, customer portal/payment-method URL | Return only after authorization; short-lived; do not log or persist; the checkout controller emits a manual redirect without framework URL logging |
| PII | Email address, optional billing/customer identifiers, IP/user agent | Minimize, access-control, redact logs, retain only for defined purpose |
| Tenant business data | Organization memberships, product resources, assignments, usage | Non-null tenant ownership, scoped query, policy, database constraints, backup encryption |
| Authorization catalog | Stable-keyed plans, entitlements, roles, permissions, local plan prices | Reviewed platform-admin commands, immutable identities, database constraints, append-only audit trail; display names never grant access, while only the unique active free plan is a fallback |
| Operational metadata | Event fingerprint, status reason code, timestamps, request/job IDs | Retain for diagnosis without raw payloads or secrets |

The webhook ledger stores an allowlisted normalized envelope, exact-body
SHA-256, environment-qualified content fingerprint, and an optional unique
provider event ID when supplied; it never stores raw provider payloads.
Passwords, API credentials, signatures, and plaintext tokens are never stored.

## 4. Trust boundaries

1. **Browser to Rails:** every parameter, ID, slug, Turbo request, and redirect
   value is untrusted.
2. **Lemon Squeezy webhook to Rails:** untrusted until exact raw-body signature,
   event, store, and environment validation succeeds.
3. **Rails to Lemon API:** authenticated outbound boundary with fixed origin,
   timeouts, rate limits, and strict response mapping.
4. **Web to Solid Queue worker:** persisted job boundary; request-local tenant
   context does not cross automatically.
5. **Rails to PostgreSQL:** primary integrity boundary; application validation
   is supplemented by constraints and least-privilege credentials.
6. **Deployment/operations:** Kamal hosts, registry, secret store, database,
   backups, and alerting are privileged infrastructure.

## 5. Threat model

| Threat | Example attack/failure | Required controls | Verification |
| --- | --- | --- | --- |
| Tenant IDOR | Member of A guesses B's slug or record ID | Account locator selects candidate only; authoritative membership and records reload through `Current.organization`; Pundit scope/policy; composite tenant FKs | Cross-tenant request/model tests for every controller family |
| Stale tenant context | Reused thread/job retains prior organization | Establish context explicitly; reset in `ensure`; fail closed without context | Sequential request/job tests including exceptions |
| Platform privilege escalation | Signup submits `system_role`, an organization owner enters `/admin`, a revoked/stale role remains accepted, or a hidden admin action is called directly | Public role parameter exclusion; explicit verified-user promotion task; live PostgreSQL role check in `PlatformAdminPolicy`; one admin base controller and policy scopes; no organization-role substitution | Task, policy, request, and system tests for ordinary user/owner denial, role revocation, and direct mutations |
| Organization privilege escalation | Admin grants owner/billing, concurrent removal leaves no owner, user disable or reactivation orphans/resurrects access, or UI-hidden POST succeeds | Exact role matrix; organization-row locking in `Organizations::Memberships::ChangeRole`/`Remove`/`Reactivate`; soft suspension removes locators/product assignments once present; server authorization; cross-organization account-disable guard added with locator/bootstrap | Table-driven service/policy, reactivation, direct request, and concurrency tests |
| Product privilege escalation | Owner assumes implicit access; billing role reaches product data; a cross-product or cross-tenant custom role is attached; suspended membership or inactive role remains effective | Central ordered Access gate: authenticated user, active tenant/member, entitlement, active product membership, non-billing role, and permission from an active correctly scoped role; no owner/admin bypass; composite tenant/product FKs plus same-tenant custom-role trigger | Constraint/trigger, central truth-table, permission-union, policy, product-assignment direct-request, and two-tenant scope tests |
| Numeric-limit race/bypass | Two concurrent seat/report additions consume the final unit, a client omits/changes feature or delta, or an external downgrade deletes data | Immutable stable-key `Entitlements::Usage` registry/result; tenant-rooted active ProductMembership/AnalyticsReport counts; `LimitEnforcer` with server-owned delta one under the organization-row mutation lock; verified known plans project without destructive remediation | Parameter-tamper, exact/unlimited boundary, deterministic downgrade, no-deletion, and concurrency tests proving at most one final-slot commit |
| Webhook forgery/tampering | Attacker posts active status or modifies one byte | HMAC-SHA256 exact raw body, constant-time compare, credential separation | Official-style fixture, mutation, bad/missing signature tests |
| Webhook replay | Valid body is resent many times or an unsigned event header is changed | Signed-body event name is authoritative; fingerprint provider/configured-environment/exact-body only; unique index plus idempotent projection | Duplicate/resend/mutated-header tests and metric |
| Webhook reordering/race | Old active event overwrites expired, or two jobs race | Current provider refetch rooted in verified event, row locks, monotonic provider timestamp, conflict quarantine | Reordered/concurrent/equal-conflict tests |
| Billing confused deputy | Webhook token/variant attaches subscription to wrong organization | Purpose/expiry-signed token with tenant/price/user/nonce payload; persist only nonce digest; global provider locator selects candidate after HMAC; exact store/environment/variant/attempt cross-check; tenant reload | Mismatch/digest locator matrix tests |
| Checkout tampering | Client submits cheap variant, custom price, live/test flag, or attacker redirect | Accept local price ID only; exact active provider mapping for configured environment/store; one enabled variant; canonical pending return URL; strict response identity/expiry/test-mode/HTTPS-host validation | Request/client-parameter tests |
| Redirect-based grant | Browser fakes success URL | Return page reads local state only; no subscription mutation | Redirect/API-success tests assert unchanged access |
| Unknown provider change | New status/event/property is interpreted as allowed | Allowlist events, normalize known values, unknown/malformed deny paid-plan selection and alert; only the explicit active free fallback remains | Unknown status/event/field tests |
| SSRF | Payload relationship or redirect URL points to internal host | Fixed Lemon API origin; construct resource paths; validate checkout URL origin; never follow payload links | Adapter URL tests |
| CSRF | Malicious site changes membership or starts checkout | Rails CSRF on all session routes; exemption only for signed webhook endpoint; SameSite secure cookies | Request tests with missing token |
| Session theft/fixation | Stolen or reused session token | Secure/HttpOnly/SameSite cookies, rotate on login, revoke sessions on password/security change, TLS | Session lifecycle/request tests |
| Credential stuffing | Automated login/reset/invite guessing | Generic responses, rate limiting, strong password hashing, token entropy/expiry, alerting | Throttle and enumeration tests |
| XSS | User-controlled organization name injects script | Rails escaping, sanitized rich text only, no unsafe HTML, CSP, no secret-bearing JS | View/security-header tests and Brakeman |
| CSV formula injection | A report name or description begins with spreadsheet formula syntax | Fixed export columns, Rails-owned row selection, and neutralize leading `=`, `+`, `-`, or `@` before CSV serialization | Exporter tests for every formula prefix and ordinary values |
| SQL injection/mass assignment | Crafted sort/filter/role parameter changes arbitrary data | Active Record bind values, allowlisted sort/filter, strong parameters, server-resolved role transitions | Request/unit tests and static analysis |
| Open redirect | Client changes login return location or billing return/provider URL | Validate login destinations as internal application locations; use canonical billing return paths and allowlisted provider host/scheme | Redirect validation tests |
| Sensitive logging | Payload/email/signature/portal URL appears in logs | Parameter/header filtering, structured reason codes, no raw body logging, exception scrubbing | Log-capture tests |
| Queue abuse/failure | Large webhook bodies fill storage or worker outage leaves state pending | Body/rate limits, fast durable receipt, separate worker, queue backpressure, sweeper, age alerts | Size/load/recovery drills |
| Database corruption/loss | Constraint omission or failed host loses authorization state | FKs/checks/unique indexes, managed PostgreSQL, encrypted backups, point-in-time recovery where available, restore drill | Constraint suite and restore evidence |
| Supply-chain compromise | Vulnerable gem/import or poisoned image | Locked dependencies/checksums, Dependabot, Bundler Audit, Importmap audit, Brakeman, pinned CI actions, image scanning/signing policy | CI gates |
| Unsafe deployment | Migration breaks old code or worker processes mixed schemas | Backward-compatible expand/contract migrations, predeploy migration job, health checks, rollback plan | Staging deploy/rollback smoke |

## 6. Tenant isolation controls

Tenant isolation is layered:

1. **Routing:** all ordinary tenant routes use `/o/:organization_slug/`.
2. **Bootstrap:** after the locator/path rollout, a global access locator selects
   an active candidate organization; the authoritative active membership is
   reloaded through that organization.
3. **Query ownership:** every tenant-owned child query begins from
   `Current.organization`.
4. **Policy:** Pundit policy scope and record policy re-check organization and
   capability.
5. **Database:** tenant-owned rows carry `organization_id`; composite foreign
   keys reject cross-tenant relationships.
6. **Context lifecycle:** `Current` is reset after every request and job.

Do not use tenant `default_scope`, unscoped child `find`, controller-wide ID
loaders that run before tenant setup, or global uniqueness/locator presence as a
substitute for scope. Invitation, job, and verified webhook context establishment
follow the bounded procedures in the authorization model.

Support impersonation and arbitrary cross-tenant product-data access remain
non-goals. The sole MVP diagnostic exception is the dedicated read-only admin
billing surface: a platform administrator submits one exact organization
`public_id`, without a global organization dropdown, sets
`Current.organization`, and reads only its subscription association. It does not
reuse tenant controllers, establish membership, or grant mutation authority.
Subscription and global failed-webhook ledger indexes are each bounded to 100
rows per page.

`AnalyticsReport` is tenant-owned even though its route uses a globally unique
`public_id`. Index/scope queries start from
`Current.organization.analytics_reports`, and show/export resolve the public ID
through that association before policy evaluation. A guessed report ID from a
different tenant is therefore not found; UUID opacity is not treated as an
authorization control.

## 7. Authentication and account security

- Use Rails-native password authentication with a current secure password
  digest algorithm and framework defaults.
- Normalize email consistently in application and database. Registration
  creates a global account only and never creates an organization; an existing
  normalized email receives no account-existence-revealing response.
- Require the current normalized email to be verified and the account to be
  enabled before session creation. Use the same generic login failure for an
  unknown email, wrong password, unverified account, and disabled account; use
  generic reset and verification-delivery responses as well.
- Store sessions server-side. Persist an opaque high-entropy raw token only in
  an `HttpOnly` cookie, handle it transiently during authentication, persist
  only its SHA-256 digest server-side, expire it after 30 days, and rotate
  browser/server session state on authentication. Revoke applicable sessions
  on logout, password reset, account disablement, and other security-sensitive
  changes. Runtime authorization revalidates the live unexpired session row and
  current verified/enabled user state instead of trusting cached model objects.
- Never accept `system_role` from public signup or account-update parameters.
  Promote the first platform administrator only with the explicit email-based
  Rake task, which normalizes and locks the account and rejects missing,
  unverified, or disabled users. Revalidate the role from PostgreSQL on every
  `/admin` request.
- Account disablement remains unexposed until its dedicated guard locks affected
  organizations and rejects a disable operation if it would leave any
  organization without another enabled active owner.
- Cookies are `HttpOnly`, `Secure` in production, and an appropriate `SameSite`
  setting. All production traffic uses HTTPS.
- Password reset uses a purpose-scoped Rails signed token that expires after 15
  minutes and is bound to password state; email verification uses a separate
  signed token that expires after 24 hours and is bound to the normalized email
  and verification state. A successful state change invalidates either token,
  making it single-use. Invitation tokens remain random, expiring, single-use,
  digest-only values bound to the authenticated normalized email.
- Filter reset, verification, and invitation token keys in both query and form
  parameters. A token-bearing `GET` only renders confirmation; a
  CSRF-protected `PATCH` performs the state change. Invitation confirmation
  responses use `Cache-Control: no-store` and `Referrer-Policy: no-referrer`.
  An unauthenticated invitation request does not persist its raw-token URL as a
  post-login destination; the user signs in or registers and reopens the email
  link. Tokens never appear in route path segments or logs.
- Validate every post-login destination as an internal application location;
  reject protocol-relative, absolute external, and malformed destinations and
  fall back to a fixed internal path.
- Rate-limit registration, login, reset request/update, verification
  delivery/confirmation, invitation acceptance, checkout creation, and webhook
  ingress at the proxy and/or application with separate thresholds.
- MFA/SSO are out of MVP, so owner/billing and platform-admin accounts carry
  residual phishing risk. This is documented and revisited before enterprise
  onboarding; platform-admin accounts should not be used for ordinary tenant
  work.

## 8. Authorization controls

The normative decision flow is in
[Authorization Model](authorization_model.md). Security-specific requirements:

- Enable Pundit verification hooks in authenticated controllers.
- Require `PlatformAdminPolicy` for every `/admin` route and return an empty
  policy scope to ordinary users. Organization ownership is not platform
  authority, and hiding the admin link is not a control.
- Treat every submitted organization/member/product/role/permission/price ID as
  untrusted and re-resolve it through owned associations/catalog allowlists.
- Treat `PlanPrice` and its Lemon identifiers as catalog input only. Checkout
  requires an exact active `Billing::ProviderPriceMapping` for the server-owned
  test/live environment and configured store; neither row proves payment or
  subscription eligibility. Lock commercial and provider-mapping identity after
  any mapping, checkout, subscription, or plan-change history references the
  price; use a new price row for corrected terms.
- Do not use owner/admin organization role as a product permission shortcut;
  billing organization membership is categorically ineligible for product-data
  access.
- Product-RBAC persistence commands remain transactional and are not their own
  authorization boundary. The customer controller first applies
  `ProductMembershipPolicy`, resolves the target through
  `Current.organization`, and passes the actor into the command. The command
  then revalidates live owner/admin authority and entitlement under the
  organization lock before changing or auditing an assignment.
- Permit global system roles across tenants, but permit a nullable
  organization-scoped role only for a product membership from that same
  organization. Enforce this conditional rule in PostgreSQL as well as the
  model/service layer.
- Ignore inactive roles and suspended product memberships in the live
  `Access::PermissionChecker` permission union. Product suspension preserves
  role joins; organization
  membership suspension deletes every product assignment before changing the
  parent status, so reactivation cannot silently resurrect access.
- Cache only the primitive entitlement catalog snapshot across requests. Key it
  by plan/subscription/catalog record versions; re-evaluate subscription time
  boundaries and all tenant/RBAC/record decisions on every request.
- Put active-owner role/status checks, access-eligible-owner account-disable
  checks, product-assignment removal, and numeric consumption checks in locked
  service/product-command transactions, not view helpers or preflight requests.
  The Tenancy-owned commands are exposed as
  `Organizations::Memberships::ChangeRole`,
  `Organizations::Memberships::Remove`, and
  `Organizations::Memberships::Reactivate`; `Remove` soft-suspends and never
  deletes the membership row.
- Keep numeric measurement in the immutable tenant-scoped
  `Entitlements::Usage` registry/result and finite/unlimited comparison in
  `Entitlements::LimitEnforcer`. The supported stable keys are each product's
  `seat_limit`, measured from its active tenant product memberships, and
  Analytics `report_limit`, measured from tenant reports. Do not resolve a class
  from database text, trust a submitted count/delta, or cache usage across
  requests.
- Resolve permission/feature/consumption behavior from a server-owned action
  registry; never accept those security semantics as optional client input.
- For Analytics, use only the reviewed `dashboard_read`, `report_read`,
  `report_create`, `report_manage`, and `export_run` registry entries. Report
  creation derives a delta of one, rechecks access inside the locked command,
  and measures usage through `Current.organization.analytics_reports`.
- Product-membership add/reactivate derives the same delta of one and measures
  active rows for the selected product through
  `Current.organization.product_memberships`. Both it and report creation hold
  the organization lock through measurement and mutation. Exact capacity is
  allowed; unlimited skips only the numeric ceiling.
- Treat usage above a projected limit as derived state. It blocks only new
  consuming/increasing commands; it does not itself deny reads that pass the
  remaining gates, and capacity-releasing operations remain available. UI
  hiding or a preflight result is never the enforcement boundary.
- Audit both successful sensitive changes and denied high-risk attempts without
  logging sensitive input.
- Route catalog writes through the transactional audited persistence command;
  keep stable keys/identity associations immutable, deactivate product/feature/
  plan/price records instead of deleting them, and preserve a disabled
  entitlement row rather than deleting history. A new plan-product requires an
  active plan and product, a new plan-price requires an active plan, and a new
  entitlement requires its plan, product, and feature to be active. Inactive
  parents retain existing relationships for catalog and billing history but
  cannot receive new ones.
  The UI does not expose entitlement settings, and the generic `settings`
  parameter is log-filtered.

## 9. Billing boundary controls

The complete flow is in [Billing Model](billing_model.md). Required security
properties are:

The implemented boundary includes an environment-qualified provider-price
mapping, an immutable checkout-token locator, a strict one-attempt Lemon
checkout client operation, and owner/billing-only checkout and pending-return
controllers. It now also includes an isolated exact-body webhook controller,
constant-time HMAC verifier, durable idempotent global receipt, and Solid Queue
processor/recovery sweeper. The processor uses the subscription locator, exact
provider refetch, tenant re-establishment, and locked projection transaction.
The read-only Entitlements policy consumes only synchronized current local
subscription rows; neither checkout nor receipt alone can create or mutate
them. Verified-event projection is the only permitted writer.

The customer billing overview loads the current
subscription through `Current.organization.billing_subscriptions`, displays
local effective-plan/status information, and performs no provider request.
Pricing is a local catalog GET, but an active owner/billing member may submit
separate CSRF-protected checkout, fresh-portal, and plan-change POSTs. Portal
URLs are exact-host validated, returned with no-store/no-referrer, and never
persisted or logged. A plan-change response writes command state only; the
canonical pending return page and billing GET read only local state, and only a
verified webhook projector mutates subscription authority.

- Store API keys and webhook secrets only in environment/credential stores.
- Use separate live/test keys, webhook endpoints/configuration, and mappings.
- Authorize checkout server-side for a live active owner/billing membership,
  rate-limit by user and organization, and rely on the database partial unique
  index to permit at most one pending attempt per organization. UI visibility is
  never the authorization boundary.
- Verify HMAC against exact raw bytes before parsing; compare constant-time.
- Support previous signing key only during a bounded, observable rotation.
- Persist only after verification and acknowledge only after durable receipt.
- Deduplicate with a database unique fingerprint and project under a row lock.
- Create a purpose- and expiry-scoped `MessageVerifier` token containing only
  organization public ID, local price ID, initiating user ID, a high-entropy
  nonce, and expiry. Persist only `SHA256(nonce)` in the tenant attempt and
  global locator; send the raw signed token only in the provider custom field.
  Verified ingress checks the signed token before digest lookup and may retain
  only the digest plus its bounded non-secret organization/price/user/expiry
  claims in the screened event envelope. It uses the global locator only for
  discovery, then reloads through `Current.organization`; the nonce and raw token
  are never stored.
- Treat subscription-invoice payment webhooks only as fixed subscription-refetch
  triggers. Never translate an invoice `paid` or `pending` value directly into a
  local subscription status or entitlement decision.
- Never use email/name/slug or a browser callback to attach a subscription.
- Construct outbound URLs from a fixed API base; use connect/read timeouts and
  response size limits. The low-level client performs no automatic retry;
  checkout sends exactly one non-idempotent POST. Timeout, connection, `408`,
  `429`, other non-allowlisted responses, 5xx, malformed JSON, and semantically
  invalid success responses remain ambiguous `creation_unknown`; local
  request/configuration errors and the explicit provider no-create allowlist
  (`400`, `401`, `403`, `404`, `422`) may resolve definitively. Never blindly
  repeat checkout creation.
- Generate the return URL from the canonical tenant pending route, reject query,
  fragment, userinfo, and wrong host/path, and require HTTPS in production.
  Validate the provider checkout URL against one configured HTTPS hostname.
  Do not persist or log the signed URL.
- Persist only bounded, screened diagnostic snapshots. Despite the compatibility
  name `raw_payload` on subscriptions, it may not contain the raw webhook body,
  full provider response, authentication/signature/token material, personal
  data, custom data, or signed URLs.
- Unknown/mismatched provider input becomes fail-closed local state only when
  tenant/subscription correlation is safely resolved; otherwise the global
  projection event is marked with a redacted permanent failure and no tenant is
  guessed. `quarantined` is reserved for deterministic ingress-envelope
  rejection before projection.
- Once a verified event resolves an exact known provider variant, always project
  that plan even when authoritative usage exceeds its limits. Never retain the
  old plan, reject the known projection, or delete/suspend product memberships or
  reports as compatibility remediation. A matching plan-change command becomes
  applied; the central usage layer derives the over-limit warning afterward.
- Application-originated downgrade preflight may block an incompatible provider
  command. Its tenant-scoped result includes only the minimum newest-first
  remediation candidates (`created_at DESC, id DESC`), is visible only on the
  authorized billing surface, and never mutates rows or writes candidate labels
  to logs/audit payloads.
- Portal/payment URLs are just-in-time, never persisted/logged.
- Reconciliation detects drift but cannot independently grant/revoke; a verified
  webhook remains the root of every subscription mutation.

## 10. Web application controls

- Keep Rails CSRF enabled everywhere except the exact signed webhook action.
- Use strong parameters and explicit command objects for sensitive transitions.
- Rely on escaped Rails templates; any sanitizer has an allowlist and tests.
- Introduce an enforced Content Security Policy before production. Start with
  report-only in staging, remove inline script/style dependencies where needed,
  then enforce. Tailwind output is static.
- Set secure headers including frame restrictions, content type options,
  referrer policy, and permissions policy appropriate to actual features.
- Configure `force_ssl`, `assume_ssl` behind the trusted proxy, HSTS, allowed
  hosts, canonical mailer URL, and trusted proxy forwarding.
- Preserve Rails query parameterization; allowlist dynamic ordering/column
  selection.
- Return generic production errors with request IDs; do not expose stack traces,
  schema, provider bodies, or configuration.
- Apply bounded request-body and form-field limits to expensive endpoints.

## 11. Secrets and configuration

- Never commit real secrets, production credentials, private keys, webhook
  payloads, or real customer fixtures.
- `config/master.key` remains ignored and outside the Docker build context.
- Kamal/environment secret injection supplies production values. Example files
  contain names/placeholders only.
- Limit credential access by environment and process. Web workers need only
  required keys; database and provider keys use least privilege available.
- Rotate session/reset/verification/invitation secrets through
  framework-supported methods;
  rotate Lemon signing secrets with an explicitly timed current/previous window.
- Secret values are filtered from exceptions, job arguments, Rails parameter
  logs, shell history, CI output, and monitoring tags.
- Production credentials are never used in development, tests, or provider
  fixture generation.

## 12. Database and backup security

- Require encrypted PostgreSQL connections where the database is remote.
- Restrict network access to application/administrative hosts.
- Application credentials do not have superuser, role-management, or database
  creation privileges in steady state; migrations use a controlled deployment
  identity when separate privileges are necessary.
- Enforce all relationships and type/range invariants described in
  [Data Model](data_model.md).
- Encrypt database volumes and backups using the hosting provider or equivalent
  infrastructure controls.
- Automate backups and monitor failures. Complete a restore drill into an
  isolated environment before launch and on a scheduled cadence.
- Restrict production console/database access, require individual operator
  identity, and record administrative actions.
- Container-local Active Storage is not durable customer storage. The MVP has no
  user uploads; a future upload feature requires private object storage,
  authorization, malware/content controls, and retention design.

## 13. Logging, privacy, and retention

Logs use stable IDs and reason codes. Do not log:

- passwords, password confirmations, and session/reset/verification/invitation
  tokens;
- authorization/API headers, cookies, webhook signature or body;
- Lemon API keys, checkout or portal URLs;
- unnecessary email/name/address/payment metadata.

Rails parameter filtering is not sufficient for infrastructure that records
the original request target. Reverse-proxy, load-balancer, CDN, and APM request
logging must redact or omit sensitive query values, including `token`, before
production traffic is enabled.

Suggested MVP retention, subject to legal/product review:

- application request logs: 30 days;
- security/audit events: 180 days;
- webhook normalized ledger and billing operational metadata: 180 days or the
  minimum required for support/accounting evidence;
- expired/revoked invitation metadata: 30 days after expiry/revocation;
- database backups: documented rotating schedule with expiry and deletion.

Retention jobs are tenant-aware where applicable, idempotent, tested, and must
not delete active billing evidence. A formal privacy/export/deletion program is
required before collecting data beyond MVP fields.

The MVP audit sinks are the append-only PostgreSQL `audit_events` tenant ledger
and the separate `platform_audit_events` global catalog ledger defined in the
data model, not an unresolved external-sink choice. Ordinary application code
cannot update either ledger; retention paths, if approved, are separately
authorized and tested.

## 14. Availability and abuse controls

- Run Solid Queue in a separate production worker process and monitor heartbeat,
  queue age, failures, and retries.
- Rate-limit authentication, invitations, checkout, portal URL generation, and
  webhook ingress without using IP alone as tenant identity.
- Bound provider timeouts and retries so a provider outage cannot exhaust web
  threads. Checkout fails pending/closed; existing authorization continues from
  local state and time bounds.
- The webhook endpoint durably accepts quickly; workers absorb downstream
  provider latency.
- Deterministic ingress mismatches quarantine; permanent projection failures
  are recorded as failed, and transient processing is capped at eight claims
  before `retry_exhausted`.
- Liveness does not depend on Lemon Squeezy. Readiness checks require database
  connectivity and remain non-public or minimally revealing.
- Capacity and incident thresholds are defined before launch, including oldest
  webhook age and past-due grace expiry risk.
- Read-only provider reconciliation runs at least every six hours; drift alerts
  are acknowledged within 30 minutes and repaired by provider resend or
  verified-event replay within four hours.

## 15. CI and secure delivery

Every PR must pass, once the foundation PR enables them:

```text
bin/rails db:prepare
bin/rails test
bin/rails test:system
bin/rails zeitwerk:check
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
docker build -t rails_sass:ci .
```

CI uses disposable PostgreSQL credentials and synthetic data. It never receives
production Rails/Lemon/database credentials. Provider contract tests use
sanitized fixtures and locally generated test secrets.

Deployment requirements:

- reviewed, backward-compatible migrations;
- dependency/image vulnerability review;
- immutable image reference/digest;
- predeploy database preparation/migrations;
- web and worker boot smoke;
- health verification and rollback procedure;
- no secrets in image layers or build arguments.

## 16. Security verification plan

### Automated

- Tenant isolation request/service/job tests for every tenant resource.
- Organization role and product decision truth tables.
- Direct POST/Turbo request tests proving UI absence is irrelevant.
- Database constraint and invalid composite-association tests.
- Last-owner role-change/removal and numeric-limit concurrency tests, including
  product-seat add/reactivate and Analytics report creation; add
  account-disable races with the locator/bootstrap follow-up.
- Analytics request/system tests for missing entitlement versus missing
  permission, direct create/show/export authorization, finite limit exhaustion,
  and two-tenant not-found behavior; exporter tests neutralize spreadsheet
  formula prefixes.
- HMAC, replay, ordering, variant/environment mismatch, redirect-no-grant, and
  status matrix billing tests. Known mapped downgrade tests prove projection,
  matching plan-change confirmation, deterministic newest remediation
  candidates, derived over-limit enforcement, preserved reads, and no data
  deletion.
- WebMock denies non-local network access; fixed-origin adapter tests stub every
  success/failure and prove redacted errors plus single-attempt POST behavior.
- CSRF, open redirect, log redaction, body limit, and rate-limit tests.
- Registration/verification gating, reset/verification expiry and reuse,
  session rotation/revocation/expiry, and generic-response enumeration tests.
- Brakeman, dependency audits, RuboCop, eager-load and image-build checks.

### Manual/staging

- Browser/session cookie and security-header inspection.
- Two-tenant adversarial ID/slug exercise.
- Lemon Squeezy test-mode lifecycle, resend, duplicate, and out-of-order drill.
- Signing-secret rotation drill.
- Worker outage/recovery and oldest-event alert drill.
- Database restore, deploy rollback, and credential revocation drill.

## 17. Incident response

Minimum runbooks cover:

- suspected tenant data exposure;
- compromised user/session or owner/billing account;
- Lemon API key or webhook secret compromise and rotation;
- webhook backlog, mapping conflict, or incorrect plan projection;
- database loss/corruption and backup restoration;
- vulnerable dependency/image rollback.

For billing incidents, revoke/rotate credentials, preserve redacted ledger/audit
evidence, fail closed for paid-plan selection on uncertain mappings, leave only
the explicit active free fallback, request provider webhook resend, and
reprocess only verified events. Direct subscription edits are prohibited.

## 18. Accepted MVP risks and deferred controls

- MFA, SSO, SCIM, dedicated support impersonation, PostgreSQL row-level security,
  WAF-specific configuration, and formal external penetration testing are
  deferred. Tenant isolation and server authorization are not deferred.
- Organization slugs expose a tenant-readable identifier to members and may be
  guessable; membership-scoped resolution prevents this from granting access.
- Product/catalog management is restricted to the internal platform-admin
  command surface; that credentialed operator boundary remains privileged and
  all writes require append-only audit evidence.
- Flat plan entitlements are not historical versions. A reviewed catalog change
  can affect every synchronized subscription referencing that plan, so catalog
  write access and audit evidence are production-sensitive.
- The configurable local past-due grace policy (15 days by default) accepts
  bounded overgrant risk to avoid immediate interruption during provider
  retries.
- A completely missed terminal webhook can leave local `active` access in place
  until the six-hour reconciliation detects drift and an operator obtains a
  verified resend/replay. There is no active freshness cutoff because valid
  annual subscriptions may have sparse events; the launch drill and response
  SLO are mandatory compensating controls.
- An expired or abandoned checkout has no documented provider completion-status
  field that proves no purchase occurred before expiry. User-facing organization
  archive is therefore deferred instead of adding a guessed closure path.

These risks are reviewed before expanding to enterprise customers, sensitive
regulated data, or broader administrative access.

## 19. Production security acceptance

- All tenant and authorization invariants have automated negative tests.
- No secret or real customer data exists in repository history, fixtures, image,
  CI logs, or documentation.
- TLS, HSTS, secure cookies, allowed hosts, CSP, redaction, and rate limits are
  verified in staging.
- Webhook forgery/replay/order/confusion tests and operational resend/rotation
  drills pass.
- Worker alerts, backup monitoring, and isolated restore evidence exist.
- A security reviewer confirms that every product and billing mutation is
  server-authorized and tenant-scoped.
- Every `/admin` request revalidates the live platform role; catalog writes retain
  immutable identity and audit evidence, diagnostics are read-only, and rendered
  pages contain no API/webhook secret, raw payload, or stored JSON snapshot.
