# MVP Security Review

Status: Application release candidate GO; production cutover NO-GO pending the
operational evidence in section 8
Review date: 2026-08-02

## 1. Executive decision

The reviewed application code has no open critical- or high-severity security
finding. The high-impact authorization, secret-disclosure, and production
transport/configuration gaps found during this review were fixed and covered by
regression tests. Known vulnerable Rails/HTML-sanitization dependencies were
upgraded to patched releases.

The application is a **GO as a release candidate**. Production cutover remains
a **NO-GO** until the deployment team records the staging and infrastructure
evidence listed in section 8. Those gates are operational controls, not code
TODOs, and cannot be proven from the repository alone.

## 2. Scope and method

The review covered routes, controllers, session bootstrap, models, policies,
service commands, jobs, mailers, views, provider adapters, migrations and the
PostgreSQL structure, production configuration, tests, and dependency locks.
The adversarial cases included:

- authentication, session fixation, session revocation, and cookie attributes;
- password-reset, email-verification, and invitation token expiry, binding,
  reuse, concurrency, caching, referrer, and log exposure;
- CSRF, authorization coverage, authoritative-role checks, tenant isolation,
  IDOR, mass assignment, and platform-administrator access;
- open redirects, provider URL validation, SQL injection, XSS, CSP, Host
  Authorization, TLS enforcement, and generic exception responses;
- exact-body webhook authentication, constant-time comparison, signing-key
  rotation, body limits, replay/duplicate handling, and ingress throttling;
- sensitive application/mailer logging and recursively nested JSONB data; and
- static analysis, dependency advisories, style, autoloading, unit/integration,
  and browser system tests.

This was a repository and local-container review. It was not an external
penetration test, cloud/IAM assessment, WAF review, or production-data audit.

## 3. Remediated findings

| ID | Severity | Finding | Resolution and evidence |
| --- | --- | --- | --- |
| SEC-001 | High | Product-membership persistence commands permitted an omitted actor, turning a controller check into the only authorization boundary. | Commands now require a persisted actor, bind it to the live `Current` user/session/membership, reload the authoritative role, recheck entitlement under lock, and always create audit evidence. Actorless, revoked-session, stale-role, cross-product, and cross-tenant tests deny writes. |
| SEC-002 | High | Platform catalog and provider-price mapping commands could trust a detached administrator argument without binding it to the active authenticated session. | Both commands lock and reload the administrator and require the same live `Current.user` and unexpired server session. Tests cover missing, different, disabled, demoted, and session-revoked administrators. |
| SEC-003 | High | Rails' default mail delivery notification exposed the complete encoded account email and recipient metadata to instrumentation subscribers. Password-reset and verification messages therefore exposed signed tokens to APM/log subscribers. | `ApplicationMailer` now emits a centrally filtered notification for every mailer. It retains only the mailer name, message ID, and delivery flag; body, recipients, sender, and subject are omitted. Regression tests cover reset, verification, invitation, and billing lifecycle mail. |
| SEC-004 | High | Production did not have a fail-closed canonical-host/TLS/session-cookie baseline in repository configuration. | Production now requires one hostname-only `APP_HOST`, allowlists exactly that host outside `/up`, generates HTTPS mail links, enables `assume_ssl`, `force_ssl`, one-year HSTS, and explicit `Secure`, `HttpOnly`, `SameSite=Lax` session cookies. Boot tests reject missing and URL-shaped hosts. |
| SEC-005 | High | A login could finish checking the old password immediately before a concurrent password reset, then insert a fresh valid session after the reset deleted existing sessions. | `Accounts::Authenticate` now captures the successfully authenticated snapshot, locks the user, verifies the email/password digest and account state are unchanged, and issues the session under the same row lock used by reset. A deterministic concurrency test proves reset-first denies old-password issuance; login-first is ordered before reset and its session is deleted. |
| SEC-006 | Medium | Reset and verification mutations validated a token before changing state without serializing concurrent use. Two requests could pass the initial single-use check. | Transactional account commands lock the user and revalidate the token and account state after the lock. Concurrency tests prove exactly one reset/verification effect and reset revokes all sessions. |
| SEC-007 | Medium | Several policies and tenant/billing commands trusted cached user, membership, organization, or role state after database revocation. Some top-level controllers lacked explicit Pundit verification. | Policies now require an authenticated context and authoritative active rows/roles. Tenant, invitation, checkout, portal, plan-change, and organization commands require a live server session. Active-session and organization controllers now authorize explicitly and use Pundit verification hooks. Negative stale-session/role and two-tenant tests were added. |
| SEC-008 | Medium | The public webhook endpoint had a body limit and durable deduplication but no application ingress rate limit. | It now allows 300 requests per minute per effective remote IP from the shared cache and returns `429` with `Retry-After: 60` before reading the body or computing an HMAC. Tests prove the limited request is neither verified nor persisted. |
| SEC-009 | Medium | Webhook secret replacement had no bounded overlap mechanism, encouraging either downtime or an indefinite extra signing key. | One distinct previous secret is supported only with a strict UTC expiry in the next seven days. Production fails boot for partial, stale, malformed, duplicate, or excessive overlap. Verification computes all eligible HMACs before selecting a slot, logs only a bounded previous-key marker, and deduplicates the same body across keys. |
| SEC-010 | Medium | `PlanFeatureEntitlement.settings` was an unbounded JSONB object and could persist recursively nested secret-shaped keys. Initial screening also treated only `_` and `-` as separators, and JSON text size could understate PostgreSQL JSONB storage. | The model now caps both JSON text and actual bind-calculated PostgreSQL storage at 64 KiB, caps depth at 20, and recursively rejects sensitive key names after normalizing every non-alphanumeric separator, with one normalized allowlisted safe key. PostgreSQL enforces object type and stored size. Migration, model, catalog-audit, separator-bypass, storage-size, and legacy-payload presentation tests were added. |
| SEC-011 | Medium | The locked bundle contained known Rails/HTML sanitization advisories. | Rails was upgraded to 8.1.3.1, Loofah to 2.25.2, and `rails-html-sanitizer` to 1.7.1. The updated advisory database reports no vulnerable gems. |
| SEC-012 | Low | A protected request could place an unnecessarily large internal return location in the encrypted cookie session. | Authentication destinations are capped at 2 KiB before persistence and continue to reject absolute, protocol-relative, backslash/control-character, decoded protocol-relative, and malformed values. |
| SEC-013 | Low | Several state-changing account, invitation, and session endpoints relied on global Rails CSRF behavior without endpoint-specific regressions. | Missing-token tests now cover login, registration, reset request/update, verification request/update, invitation create/revoke/accept, logout, and active-session revocation. Only the exact HMAC-authenticated webhook controller is outside the browser controller/CSRF stack. |
| SEC-014 | Low | Account and invitation token consumers accepted arbitrarily large raw strings before signed-token decoding or digest calculation. | Reset, verification, and invitation tokens are capped at 2 KiB before decoding, hashing, or database lookup. Regression tests prove oversized account tokens perform no user query and oversized invitations are not digested. |

No finding in this table is deferred or left as a TODO.

## 4. Control verification matrix

| Requested area | Result | Implemented control/evidence |
| --- | --- | --- |
| Authentication | Pass | Normalized email, password-digest authentication, verified/enabled gating, generic failure responses, live authentication revalidation, and row-locked post-authentication snapshot validation. |
| Session fixation and cookies | Pass | Login issues a new 256-bit opaque token under the user lock, stores only its digest, destroys the prior browser session, and calls `reset_session` before installing the new cookie. Both Rails and authentication cookies are explicit `HttpOnly`, `SameSite=Lax`, and production `Secure`. |
| Reset and verification tokens | Pass | Separate purpose/expiry/state-bound signed tokens; 2-KiB pre-decode bound; confirmation only on CSRF-protected `PATCH`; post-lock revalidation makes mutation single-effect under concurrency; token responses are no-store/no-referrer. |
| Invitation tokens | Pass | Random high-entropy token, 2-KiB pre-digest bound, digest-only persistence, expiry/revocation/single-use checks, authenticated normalized-email binding, tenant reload, no raw invitation URL stored for post-login redirect, no-store/no-referrer responses. |
| CSRF | Pass | Rails forgery protection remains enabled for browser mutations; explicit negative request tests cover each sensitive endpoint family. Webhook authentication uses exact-body HMAC instead of a browser session. |
| Authorization coverage | Pass | Pundit verification hooks and policies protect resource actions; sensitive service commands independently bind actors to live sessions and authoritative rows. Logout is a documented narrow self-session operation with no caller-selected record. |
| Tenant isolation and IDOR | Pass | Tenant children are resolved through `Current.organization`; submitted IDs are re-resolved through tenant associations/catalog allowlists; composite constraints and two-tenant negative tests prevent cross-tenant reads/writes. |
| Mass assignment | Pass | Strong parameter allowlists and explicit command inputs exclude `system_role`, tenant ownership, provider identity, roles, permissions, and billing authority. Catalog attributes use per-record allowlists and immutable identities. |
| Open redirect and unsafe URLs | Pass | Post-authentication destinations accept only bounded internal paths. Billing returns are server-generated. Checkout/portal URLs require HTTPS and exact configured hosts and are returned manually without logging or persistence. The Lemon API origin is fixed. |
| Webhook signature and timing | Pass | HMAC-SHA256 covers exact raw bytes before JSON parsing. A strict 64-character lowercase-hex shape precedes `secure_compare`; all eligible current/previous-key comparisons are computed. |
| Replay and duplicate webhook protection | Pass | Environment-qualified exact-body fingerprint and database unique index make receipt idempotent; provider event ID is additionally unique when supplied. Projection uses row locks and monotonic provider timestamps. |
| Webhook availability | Pass in application; edge gate pending | Body is capped at 256 KiB plus one-byte detection. Application ingress is 300/minute/IP before body/HMAC work, high enough for legitimate retries. Edge/global capacity protection and proxy trust require staging evidence. |
| Admin access | Pass | Every `/admin` request reloads a live platform role; tenant organization roles confer no platform access. Diagnostics are read-only and bounded, and catalog/mapping writes reauthorize under lock with append-only audits. |
| Sensitive logging | Pass in application; infrastructure gate pending | Parameter/header filters, generic reason codes, manual signed-URL redirects, body-free webhook logs, and central mail instrumentation filtering prevent known application leaks. Proxy/CDN/APM query redaction needs staging evidence. |
| Exception messages | Pass | Production local error reports are disabled; controllers return generic 403/404/provider/authentication messages; webhook internal failures log a reason code and request ID without exception/body/signature. |
| JSONB sanitization | Pass for application writes | Billing/audit JSONB already uses allowlisted bounded snapshots. Entitlement settings now add separator-normalized recursive secret-key/depth checks, bind-calculate PostgreSQL storage size, and have a database type/size constraint. Direct privileged SQL is addressed as an accepted operational risk. |
| SQL injection | Pass | Reviewed dynamic queries use Active Record binds and allowlisted stable registries/orderings. No caller-controlled table, column, SQL fragment, or class resolution was found; Brakeman reports no warning. |
| XSS and CSP | Pass | Rails output escaping is retained; adversarial tenant text remains escaped. Enforced CSP uses self/none directives and a fresh nonce for importmap scripts, with no `unsafe-inline`; clickjacking/content-sniffing/referrer/permissions headers are tested. |
| Host Authorization | Pass | Production refuses a missing/malformed canonical host and accepts exactly `APP_HOST`; only the minimally revealing `/up` probe is excluded. |
| Production SSL | Pass in configuration; topology gate pending | `assume_ssl`, `force_ssl`, secure cookies, HTTPS mail URLs, and one-year HSTS with subdomains are configured. Direct container exposure remains forbidden and must be verified at deployment. |

## 5. Rate-limit inventory

All application limits use `Rails.cache`; production uses the shared Solid Cache
store. Authenticated limits use user plus organization rather than treating an
IP address as tenant identity.

| Operation | Limit and key |
| --- | --- |
| Login | 10 requests / 3 minutes / effective remote IP |
| Registration | 5 requests / 10 minutes / effective remote IP |
| Password-reset request | 5 requests / 15 minutes / effective remote IP |
| Password-reset confirmation | 10 requests / 15 minutes / effective remote IP |
| Verification request | 5 requests / 15 minutes / effective remote IP |
| Verification confirmation | 10 requests / 15 minutes / effective remote IP |
| Invitation acceptance | 10 requests / 15 minutes / user and organization |
| Invitation create and resend | 10 requests / hour / user and organization, with separate buckets |
| Checkout creation | 5 requests / 10 minutes / user and organization |
| Portal URL creation | 10 requests / 10 minutes / user and organization |
| Plan-change creation | 5 requests / 10 minutes / user and organization |
| Lemon Squeezy webhook | 300 requests / minute / effective remote IP; `Retry-After: 60` |

The unauthenticated IP buckets intentionally do not use an email/account key,
because that would allow targeted denial of service against a known account.
Section 7 records the distributed-source residual risk.

## 6. Migration and deployment procedure

Migration `20260802090000_bound_plan_feature_entitlement_settings` replaces the
existing JSON-object check with an object-and-64-KiB check. It is reversible and
does not delete or rewrite data.

Before deployment, run a key-only/model validation preflight using the new
application image; do not print settings values:

```bash
RAILS_ENV=production bin/rails runner '
invalid_ids = PlanFeatureEntitlement.find_each.filter_map { |row| row.id unless row.valid? }
abort("Invalid PlanFeatureEntitlement rows: #{invalid_ids.join(",")}") if invalid_ids.any?
'
```

Then run:

```bash
RAILS_ENV=production bin/rails db:migrate
```

The database migration itself rejects an oversized/non-object legacy row and
rolls back rather than weakening the constraint. A normal rollback restores the
prior object-only constraint. Configure `APP_HOST` before any production boot.
For webhook-key rotation, configure the new current secret plus the old secret
and a strict UTC `...Z` expiry no more than seven days away; remove both previous
key variables after the overlap.

## 7. Accepted residual risks

These are accepted MVP risks with compensating controls, not unresolved
critical/high findings:

- MFA, SSO/SCIM, support impersonation, PostgreSQL row-level security, and a
  formal external penetration test are deferred. Platform administrators should
  use dedicated accounts; phishing exposure remains until MFA is introduced.
- A distributed attacker can spread unauthenticated attempts across IPs, and
  eligible/ineligible account paths may have a statistical timing difference.
  Generic responses, strong password/token primitives, shared limits,
  monitoring, and an edge policy are the MVP controls.
- `assume_ssl` and IP-derived throttling are trustworthy only when the
  application is reachable solely through a TLS terminator that overwrites
  forwarding headers and Rails is configured with the actual trusted proxies.
- CSP is enforced without an application CSP-report collector; staging browser
  and APM observation is the MVP signal. HSTS preload remains intentionally off
  until all production subdomains are confirmed HTTPS.
- JSON depth and secret-key semantics are model controls. PostgreSQL enforces
  object type and size, but a privileged direct SQL writer could bypass semantic
  screening; steady-state application credentials must not permit ad hoc SQL.
- The repository review cannot prove reverse-proxy, CDN, APM, backup, registry,
  host firewall, database TLS/least privilege, or secret-store behavior.

The full product/billing residual-risk register remains normative in
[Security Model](security_model.md#18-accepted-mvp-risks-and-deferred-controls).

## 8. Production cutover gates

Production remains NO-GO until all of the following evidence is attached to the
release record:

1. The application container is not directly reachable; the TLS terminator
   overwrites forwarding headers, trusted-proxy handling yields the real client
   IP, and wrong `Host` requests are rejected outside `/up`.
2. Browser inspection on the real hostname confirms HSTS, enforced CSP/nonces,
   security headers, and `Secure; HttpOnly; SameSite=Lax` cookies across login,
   reset, verification, invitation, tenant, billing, and admin flows.
3. Reverse-proxy/CDN/APM/log sinks demonstrate query-token, cookie, signature,
   raw-body, signed-provider-URL, email, and encoded-mail redaction.
4. Lemon test/live isolation, forged-body rejection, duplicate/resend and
   out-of-order delivery, old/new signing-key overlap/expiry, edge throttling,
   and worker outage/backlog recovery drills pass without entitlement overgrant.
5. Separate web and Solid Queue processes have heartbeat, oldest-webhook,
   failure/retry, cache, database, and rate-limit alerts with owners and response
   thresholds.
6. Database TLS/least privilege, encrypted backup success, isolated restore,
   migration rollback, deploy rollback, secret rotation/revocation, and
   immutable image provenance are demonstrated.

Completing these gates changes the production decision to GO without accepting
any open critical/high application finding.

## 9. Verification record

The final local verification record for this review is:

| Command | Result |
| --- | --- |
| `bin/rails test` | 751 runs, 7,453 assertions, 0 failures, 0 errors, 0 skips |
| `bin/rails test:system` | 13 runs, 154 assertions, 0 failures, 0 errors, 0 skips |
| `bin/rails zeitwerk:check` | Passed |
| `bin/rubocop` | Passed; 350 files inspected, no offenses |
| `bin/brakeman --no-pager` | Passed; 79 checks, 0 warnings, 0 errors |
| `bin/bundler-audit check --update` | Passed; 1,229 advisories checked, no vulnerabilities found |
| `bin/importmap audit` | Passed; no vulnerable packages found |
| `bin/ci` | Passed complete aggregate sequence in 1 minute 35 seconds |
| `docker build -t rails-sass:security-review .` | Passed; final image `sha256:9952b8834d1deaad933d5f0f6e37a622b9141ecbfcc9e661e47c8919fc347386` |
| Production-image Rails boot smoke | Passed as non-root runtime image with canonical `APP_HOST`; Rails 8.1.3.1 |

All local repository gates completed successfully. They do not replace the
production cutover evidence above.
