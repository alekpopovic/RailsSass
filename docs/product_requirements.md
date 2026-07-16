# Product Requirements: Modular SaaS MVP

Status: Proposed
Last updated: 2026-07-16

## 1. Purpose

This document defines the production MVP for a multi-tenant SaaS platform built
as a Rails modular monolith. It specifies product behavior and acceptance
boundaries. The implementation design is defined in
[Architecture](architecture.md), [Data Model](data_model.md),
[Authorization Model](authorization_model.md), [Billing Model](billing_model.md),
and [Security Model](security_model.md).

The MVP is a platform foundation for one or more product modules. Concrete
product-domain workflows are deliberately separate from the platform contract.

## 2. Repository baseline

The repository is a Rails 8.1.3 application with PostgreSQL, Hotwire, Tailwind,
Pundit, Solid Queue/Cache/Cable, Docker/Kamal scaffolding, Minitest, and a
PostgreSQL-backed CI quality gate. Email/password authentication, organization
onboarding, and locator-backed tenant path bootstrap exist. Invitations,
audited membership administration, and the constrained local product/plan
catalog also exist. Billing now has constrained local persistence/history
primitives, exact test/live price mappings, checkout-token locators, an audited
mapping-management surface, a strict Lemon checkout operation, and
owner/billing checkout plus local pending-return endpoints. Verified webhook
ingress/projection, fresh portal retrieval, and webhook-confirmed plan-change
commands are also implemented. A
read-only local Entitlements resolver covers paid status, free fallback, and
catalog typing;
product-RBAC persistence, transactional assignment commands, and the central
runtime Access decision/Pundit integration also exist. A Pundit-protected
internal `/admin` surface now provides audited catalog maintenance and bounded,
read-only billing diagnostics for `platform_admin` users. The customer shell,
audited product-assignment UI, and a tenant-owned Analytics report vertical
slice now exercise the central action registry, product policies, CSV export,
and central Entitlements usage/limit contract for per-product seats and
`report_limit`. Checkout success and outbound subscription-update responses
change only command state and never grant access. Deployment hardening remains a
separate execution-plan milestone.

Each milestone must inspect and test existing behavior rather than assume an
earlier prompt was implemented perfectly.

## 3. Product statement

An authenticated user can participate in multiple organizations. Each
organization uses a stable-keyed effective local plan, selected from an
accessible paid subscription or the active free fallback. The plan grants
products and typed product features. Organization administrators assign members
to specific products and product roles. A product action is permitted only when
both the organization's local entitlement and the member's product permission
allow it.

Lemon Squeezy handles checkout and subscription lifecycle events. The local
PostgreSQL state is the only runtime source for access decisions. A browser
redirect or an outbound provider API response never grants access.

## 4. Personas and roles

### 4.1 User

A global account that can authenticate and hold memberships in multiple
organizations. Registration creates only this global account and does not
create an organization. A user must verify the current normalized email and
remain enabled before authenticating, and has no tenant access without an
active organization membership. Every user has a system role of `user` or
`platform_admin`. The latter may enter the internal `/admin` surface only after
the live database role is revalidated on the request. It is independent from
organization membership and grants no implicit tenant or product access.

### 4.2 Organization roles

An `OrganizationMembership` has exactly one organization role:

| Capability | owner | admin | billing | member |
| --- | ---: | ---: | ---: | ---: |
| View the organization shell | Yes | Yes | Yes | Yes |
| Update organization name | Yes | Yes | No | No |
| Invite or manage member/admin memberships | Yes | Yes | No | No |
| Grant/revoke owner or billing roles | Yes | No | No | No |
| Assign product memberships and product roles | Yes | Yes | No | No |
| View subscription and billing screens | Yes | No | Yes | No |
| Start checkout or open the customer portal | Yes | No | Yes | No |
| Use an entitled product | Product gate | Product gate | No | Product gate |

Multiple owners are allowed, but every organization must retain at least one
active owner membership. Runtime tenant access additionally requires that the
owner's global user account is enabled; the account-disable command must not
leave an organization without such an access-eligible owner. No organization
role bypasses product membership, product permission, or plan entitlement for
product-data access. The billing role is deliberately ineligible for product
data even if stale product assignment rows exist. When one account needs both
billing and product responsibilities, it must use the owner organization role
and still receive an explicit product membership and product role.

Organization membership administration is performed by the Tenancy-owned
`Organizations::Memberships::ChangeRole` and
`Organizations::Memberships::Remove` commands. `Remove` soft-suspends the
membership and does not delete its history. Billing and member roles cannot use
either command successfully; admins remain limited to member/admin memberships.

### 4.3 Product roles

The MVP uses reviewed system roles per product. A product membership can have
multiple product roles; its effective permission set is the union from active
roles only. The schema can scope a role to one organization, but a
customer-facing custom-role builder is not part of the MVP. There is no
explicit deny permission.

## 5. Immutable product invariants

1. Every ordinary tenant URL is under `/o/:organization_slug/`, except global
   account/organization creation, internal platform administration, health,
   authentication, and provider webhook routes.
2. Ordinary tenant context selects an active candidate organization through a
   non-authoritative account locator, then verifies the active membership through
   `Current.organization`; a slug/locator alone never authorizes.
3. After a candidate root is set, every tenant-owned child query is rooted at
   `Current.organization`.
4. Organization role and product RBAC are independent.
5. Product access requires a non-billing organization role, an effective local
   plan (accessible paid subscription or active free fallback), plan product
   entitlement, product membership, and product permission. The organization
   membership and product membership must be active, and only active system or
   same-organization roles contribute permissions.
6. A feature-specific action additionally requires the enabled typed feature
   entitlement. A consuming finite-limit action additionally requires capacity;
   explicit unlimited still requires every other access factor.
7. Missing, malformed, stale-conflicted, or unknown authorization input denies
   access.
8. UI visibility is advisory; every read and mutation is authorized on the
   server.
9. Runtime authorization makes no Lemon Squeezy API call.
10. Only processing rooted in a verified, durably stored, idempotent webhook
    may change local subscription state.
11. Public signup and account parameters never accept `system_role`; the first
    platform administrator is promoted explicitly by normalized email through a
    production task that rejects missing, unverified, or disabled accounts.

## 6. MVP scope

### 6.1 Identity and tenancy

- Email/password registration, verification, authentication, logout, session
  revocation, and password reset using Rails-native primitives. Registration
  never creates an organization.
- Unverified and disabled accounts cannot establish sessions. Registration
  duplicates, login, recovery, and verification-delivery responses are generic
  where account disclosure is possible, and the endpoints have separate rate
  limits.
- Password-reset tokens are Rails signed, state-bound, single-use, and expire
  after 15 minutes; email-verification tokens have the same properties and
  expire after 24 hours. Token-bearing `GET` requests only render confirmation;
  CSRF-protected `PATCH` requests perform the mutation.
- Sessions are server-side, rotate on authentication, expire after 30 days,
  and store only a SHA-256 digest of the opaque cookie token. Runtime access
  decisions revalidate the live unexpired session and verified/enabled account
  state. Redirects after authentication accept only validated internal
  application locations.
- Explicit onboarding for a verified and authenticated user; registration and
  email verification never create an organization automatically.
- Organization creation with a database-generated unique public UUID for
  external references, a globally unique normalized immutable slug, and an
  `active`/`suspended` status that defaults to `active`.
- Organization switcher for users with multiple active memberships.
- Email invitation flow with an expiring, single-use token. An invitation does
  not authorize access before acceptance.
- Organization membership management according to the role matrix.
- Safe owner transfer/demotion/removal that cannot leave an organization
  without an active owner, including concurrent membership requests; account
  disablement separately cannot remove the last access-eligible owner.
- Membership soft suspension revokes its product assignments; later reactivation
  requires explicit product reassignment.

### 6.2 Catalog and plans

- System-managed global `Product`, `ProductFeature`, `Plan`, `PlanProduct`,
  `PlanFeatureEntitlement`, and `PlanPrice` catalogs, plus system product roles
  and permissions.
- Stable product, feature, plan, role, and permission keys in English. Runtime
  lookup never identifies a catalog record by its display name.
- Products, product features, plans, and prices use explicit `active` flags.
  Creating a `PlanProduct` requires an active plan and product; creating a
  `PlanPrice` requires an active plan; and creating a feature entitlement
  requires its active plan, product, and feature. Deactivation blocks those new
  relationships while retained foreign keys preserve every existing catalog
  and billing-history row.
- `Plan.free` identifies the system-managed fallback plan. When no current paid
  subscription is access-eligible, the one active free plan is effective; it
  never creates or changes a subscription and at most one may be active.
- A `PlanProduct` row grants base product access for its plan.
- Product features are either `flag` or `limit`. A feature entitlement has an
  explicit `enabled` value; a limit is either a finite non-negative integer or
  explicitly unlimited.
- Missing or disabled feature entitlement denies the feature. Flag features do
  not carry numeric or unlimited values. A limit keeps exactly one valid finite
  or unlimited capacity even when disabled; `enabled` remains the master grant
  switch.
- `PlanPrice` stores local price display data and Lemon catalog identifiers.
  Its presence, activation, or selection never assigns a plan, changes a local
  subscription, or grants product access.
- Numeric limits apply per organization. Each consuming product action defines
  a stable registry key and uses the immutable tenant-scoped
  `Entitlements::Usage` result plus `Entitlements::LimitEnforcer`. The registry
  defines the unit and authoritative organization-scoped query; client input
  never chooses a model, count, or delta.
- Reaching a numeric limit blocks only consuming/increasing operations; reads
  and non-consuming or capacity-releasing operations remain available. Derived
  over-limit state is not a subscription status and is not persisted.

### 6.3 Product access management

- Owner/admin can add an active organization member to a currently entitled
  product and assign one or more system product roles.
- A product can declare the reviewed stable `seat_limit` feature. Its
  authoritative usage is the count of active ProductMembership rows for that
  organization and product; suspended assignments consume no seat. The local
  Core, Analytics, and CRM seed declares it. Add and reactivate enforce a
  server-owned delta of one under the organization row lock in the same
  transaction as activation whenever that limit is registered.
- Product-level suspension preserves assigned roles but grants no access until
  an explicit reactivation; removal deletes the product assignment and joins.
- Assignments may remain dormant after a downgrade or subscription loss; they
  do not grant access until the entitlement gate is true again.
- Dormancy does not apply to organization-membership removal: its soft
  suspension destroys every product assignment, and later reactivation does not
  restore them.
- Product policies use one central decision service for the shared
  entitlement-and-permission gate, then apply record-specific rules.
- Cross-organization record identifiers never expose or mutate another
  organization's data.
- The tenant product-member surface uses stable product keys and permits only
  owner/admin actors for products in the effective plan. Submitted membership,
  assignment, and role inputs are re-resolved through `Current.organization`
  or the product's active system-role allowlist; every mutation is revalidated
  and audited inside its transaction.
- The reference Analytics product provides `/analytics/dashboard`, report
  index/create/show, and CSV export routes under the tenant path. Its exact
  feature keys are `dashboards`, `custom_reports`, `csv_export`, and
  `report_limit`; its permission keys are `analytics.dashboard.read`,
  `analytics.report.read`, `analytics.report.create`,
  `analytics.report.manage`, and `analytics.export.run`.
- Analytics report creation consumes one organization-wide report slot. It
  revalidates the `custom_reports` flag, typed `report_limit`, product
  membership, and `analytics.report.create` permission while holding the
  organization lock, then invokes `Entitlements::LimitEnforcer` with delta one
  against `Current.organization.analytics_reports` and creates in the same
  transaction.

### 6.4 Billing

- Persist tenant-owned provider customers, checkout attempts, subscriptions and
  plan-change command history, plus a global minimal webhook-event ledger. Only
  the current local subscription is an Entitlements input; checkout attempts,
  plan-change commands, and outbound responses never grant or change access.
- Keep subscription history by archiving prior rows rather than deleting them,
  with at most one row marked current per organization. Archived state is
  one-way and subscription rows cannot be deleted through ordinary or direct
  table mutation.
- Access Lemon Squeezy through one fixed-origin, timeout-bounded adapter with
  redacted provider-specific failures and no blind retry of non-idempotent
  requests. Automated tests prohibit real external network access.
- Server-side checkout accepts only a local `PlanPrice` ID, then resolves and
  revalidates an active paid price and exact active
  `Billing::ProviderPriceMapping` for the configured environment and store.
  Provider IDs, environment, amount, token semantics, expiry, and return URL are
  server-owned.
- Only owner/billing may initiate checkout, request a fresh customer portal URL,
  or create a plan-change command.
- At most one current subscription and one pending checkout per
  organization.
- Only verified `expired` is terminal for replacement checkout; a new verified
  subscription atomically supersedes the expired historical row.
- The canonical checkout return page displays the latest tenant-scoped local
  attempt or synchronized subscription state; it does not mutate billing or
  entitlement records.
- Signed webhook ingestion, durable receipt, local idempotency, asynchronous
  projection, duplicate handling, and out-of-order protection.
- Subscription-to-plan mapping by exact provider environment, store, and
  variant identifiers.
- Explicit local access policy for every provider status, defined once in
  [Billing Model](billing_model.md#8-subscription-access-matrix).
- Separate Lemon Squeezy test and live credentials, mappings, and webhook
  secrets.
- Customer portal URLs are requested only after authorization and are not
  persisted or logged.
- The tenant billing overview remains local-only. Pricing may initiate checkout,
  the pending page may display attempt state, and billing management may create
  provider commands, but return navigation, portal visits, and provider API
  success never mutate a subscription, effective plan, or entitlement. Only a
  matching verified webhook projection confirms the change.
- Application-originated plan changes run a tenant-scoped compatibility
  preflight over registered per-product `seat_limit` and Analytics
  `report_limit`. An
  incompatible target is not sent to the provider and returns the minimum
  deterministic newest candidates (`created_at DESC, id DESC`) needed to reach
  capacity; the preflight never changes or deletes them.
- A verified webhook for a known mapped provider plan always projects that plan,
  including a provider-portal downgrade below current usage. It confirms a
  matching pending plan change without deleting tenant data. The resulting
  derived over-limit warning does not itself deny otherwise-entitled reads and
  blocks only later consuming operations until usage is reduced or capacity
  increases.

### 6.5 Internal platform administration

- Every `/admin` route requires a currently authenticated, verified, enabled
  user whose live database `system_role` is `platform_admin`. Organization owner
  or admin membership is neither required nor sufficient.
- The first platform administrator is promoted explicitly by an email-accepting
  Rake task. No public signup or update endpoint accepts `system_role`.
- The internal Tailwind UI manages products, features, plans, plan-product rows,
  feature entitlements, and plan prices by stable identity. Stable keys and
  identity relationships are immutable after creation.
- Catalog writes are performed by one audited mutation boundary. Product,
  feature, plan, and price lifecycle uses deactivation rather than hard delete;
  a plan product is create-only, and a feature entitlement is disabled by
  retaining its row with `enabled=false`. Cross-product or kind-inconsistent
  feature input is rejected with a visible validation error and no partial
  write.
- New plan-product, price, and entitlement relationships require active parent
  catalog records, and feature submission uses one composite stable
  product/feature identity. Existing relationships remain available for history
  and reviewed lifecycle updates after a parent is deactivated. Once any
  billing-history row references a price, its amount, interval, currency, plan,
  and Lemon identifiers are immutable in the UI; only active status may change,
  and commercial changes require a new price row.
- Subscription diagnostics are read-only and accept one exact organization
  `public_id`; they never load a global organization dropdown. Subscription rows
  are then loaded through `Current.organization.billing_subscriptions` in pages
  of at most 100. Failed webhook events are read from their global
  provider-ingress ledger in pages of at most 100.
- The admin surface never renders credentials, configuration secrets, raw
  provider payloads, diagnostic JSON snapshots, entitlement settings, or signed
  provider URLs.
- Platform administrators may create one immutable Lemon mapping per local
  price/provider/environment and toggle only its active state. Creation requires
  an active paid plan and active price, copies the price's Lemon identifiers,
  and commits audit evidence in the same transaction.

### 6.6 User experience

- Server-rendered Hotwire/Turbo flows with focused Stimulus controllers.
- Tailwind-based responsive pages for authentication, global name-only profile
  settings, organization switching/dashboard/settings, member and product-role
  administration, enabled/locked product cards, local pricing/billing state,
  and the Analytics report slice. Checkout controls, generic error feedback,
  explicit test-mode labeling, local pending/synchronized states, fresh portal
  redirects, plan-change compatibility feedback, and webhook-driven
  confirmation are implemented.
- Customer routes include `/o/:organization_slug/dashboard`, `/products`,
  `/products/:product_key/members`, `/pricing`, `/billing`,
  `POST /billing/checkouts`, `GET /billing/checkouts/pending`,
  `POST /billing/portal`, `POST /billing/plan_changes`, `/settings`, and
  the `/analytics/...` product routes. `/profile` is global and accepts only the
  authenticated user's display name; email remains read-only in this flow.
- Locked product cards name the first active plan that contains the required
  product/feature when one exists. Plan-entitlement and product-permission
  failures use distinct safe messages, while server policies still authorize
  every direct request.
- Accessible forms, validation messages, keyboard navigation, and clear 403,
  404, and billing-pending states.
- UI controls use the same permission predicates for presentation while the
  server independently enforces every request.

### 6.7 Production operations

- PostgreSQL-backed CI and Minitest coverage before behavioral work lands.
- Separate web and Solid Queue worker processes for production billing jobs.
- Docker image build, eager-load, migration, and boot smoke checks.
- Kamal-ready configuration without committed secrets or provider credentials.
- TLS, allowed-host policy, secure cookies, structured/redacted logs, database
  backups, restore drill, queue monitoring, and webhook failure alerts.

## 7. Primary user journeys

### 7.1 Create and enter an organization

1. After email verification and authentication, a user explicitly completes
   onboarding; registration itself still creates only the global account.
2. `Organizations::Create` atomically creates an active organization and its
   first active owner membership, then sets the request-local current
   organization and membership only after the outermost transaction commits.
3. The application generates its public UUID and normalizes and reserves its
   immutable slug.
4. After the locator/path-bootstrap milestone has backfilled the new active
   membership, the user enters `/o/:organization_slug/`; tenant context is
   established through that membership. No tenant path is enabled before that
   backfill is complete.
5. Without an access-granting subscription, organization administration and
   billing remain available, but product actions deny.

### 7.2 Invite and assign a member

1. Owner/admin creates an invitation within `Current.organization`.
2. The recipient authenticates and accepts the unexpired token.
3. Acceptance atomically creates or reactivates one membership for that user
   and organization.
4. Owner/admin creates a product membership and assigns product roles.
5. The non-billing member can act only if the plan and product permission gates
   also pass.

### 7.3 Subscribe

1. Owner/billing selects an active paid local `PlanPrice` whose active Billing
   mapping exactly matches the deployment's configured provider environment and
   store.
2. The server atomically creates a tenant-scoped attempt and nonce-digest
   locator, then makes one provider checkout request with a short-lived signed
   token carrying the organization public ID, price ID, user ID, nonce, and
   expiry. No raw signed token or checkout URL is persisted.
3. The browser returns to a pending page after payment.
4. A valid Lemon Squeezy webhook is verified and durably recorded.
5. Webhook ingress verifies the signed custom token, validates its bounded
   payload, hashes its nonce, and retains only that digest. Background
   processing uses the digest to resolve only a global
   non-authoritative provider locator, establishes
   `Current.organization`, validates tenant/provider mappings, and updates the
   local subscription in a transaction. Plaintext token is never persisted.
6. Subsequent requests resolve the exact local paid plan by its stable identity,
   or the active free fallback when paid access is unavailable; no request calls
   Lemon Squeezy for authorization.

### 7.4 Consume a limited feature

1. The request establishes tenant and organization membership context.
2. The common gate verifies subscription, plan product, feature, product
   membership, and permission.
3. The product command revalidates the common grant, locks or atomically checks
   `Current.organization`, measures authoritative usage through
   `Entitlements::LimitEnforcer`, and applies its server-calculated delta only
   when it remains within the local limit.
4. Concurrent requests cannot both consume the same final unit.

### 7.5 Maintain the platform catalog

1. An operator explicitly promotes an existing verified, enabled account with
   `platform_admin:promote[email]`; no browser parameter can perform this step.
2. The authenticated platform administrator enters `/admin`; the policy checks
   the live database role independently of every organization membership.
3. A catalog mutation preserves its stable identity and commits together with
   append-only platform audit evidence. Lifecycle removal uses deactivate or
   `enabled=false`, not row deletion.
4. To inspect subscriptions, the administrator explicitly selects one
   organization and the server reloads rows from
   `Current.organization.billing_subscriptions`. Failed webhook-event diagnostics
   use the global ledger. Neither view can mutate billing or reveal stored
   payload/snapshot/configuration secrets.

## 8. Non-goals

- Multiple billing providers, one-time purchases, usage-based provider billing,
  coupons, tax calculation, invoice accounting, or a custom payment UI.
- Runtime provider lookups, access changes from redirects, or access changes
  from unverified/manual database edits.
- Manual or tenant-specific entitlement grants, trials not represented by Lemon
  Squeezy, or multiple simultaneous paid subscriptions per organization. The
  only non-subscription grant is the single system-managed active free-plan
  fallback.
- Tenant-defined products, plans, permissions, arbitrary policy scripting, or a
  customer-facing custom-role builder. Nullable organization role scope is
  forward-compatible schema support, not an MVP management surface.
- Explicit deny permissions, resource-level ACL sharing, or organization role
  bypasses for product access.
- SSO/SAML, SCIM, social login, MFA, passkeys, or enterprise identity lifecycle.
- Custom domains, subdomain tenancy, database-per-tenant, or row-level security
  in the MVP.
- Metered/rolling usage windows and provider-reported usage. MVP limits are
  local finite capacity or explicit unlimited capacity, never an implicit
  sentinel.
- Support impersonation, arbitrary cross-tenant product-data browsing, user-role
  management through the browser, and destructive catalog history editing. The
  internal admin surface is limited to the documented catalog commands and
  read-only billing diagnostics.
- User file uploads unless a concrete product module requires them; local
  Active Storage is not accepted as durable production storage.
- Concrete product-domain functionality beyond the thin vertical slice needed
  to prove the platform authorization contract. The slice is limited to
  Analytics dashboard/report metadata and one-row CSV export; it is not a
  general analytics engine, query builder, or data warehouse.
- Organization archive/hard deletion. The provider does not expose an
  authoritative checkout-completion state that can safely close every abandoned
  correlation; lifecycle deletion requires a later product/operations ADR.

## 9. Success measures

- Zero known cross-tenant data access paths in the tenant isolation test suite.
- Every product permission truth-table branch and billing status is covered by
  a deterministic Minitest.
- Duplicate and reordered webhook tests produce one correct local projection.
- Checkout redirect tests prove that local access remains unchanged.
- No runtime authorization test performs a provider HTTP request.
- Production smoke deploy, backup restore, and worker recovery drills complete
  before launch.

## 10. Production MVP acceptance criteria

The MVP is acceptable when all of the following are demonstrated:

1. A user can register without implicitly creating an organization, verify the
   email, authenticate, explicitly create an organization through onboarding,
   join multiple organizations, and switch tenants.
2. A guessed organization slug or tenant record ID cannot cross tenant
   boundaries.
3. Active/suspended organization and membership state plus the organization role
   matrix are server-enforced, including the last-owner invariant.
4. A user with an organization role but no product membership/permission is
   denied product access, including owner/admin.
5. A product member with permission but no plan entitlement is denied.
6. Flag, finite-limit, and unlimited feature decisions behave as documented,
   including exact finite boundaries, per-product seat add/reactivate and report
   creation under the organization lock, and one successful final-unit mutation
   under concurrency.
7. All paid subscription status/time boundaries and active-free fallback cases
   match the canonical billing matrix.
8. A checkout redirect, outbound API success, duplicate webhook, stale webhook,
   unknown variant, and unknown status cannot over-grant access.
9. A valid webhook can activate, change, cancel, recover, and expire a local
   subscription without a runtime provider dependency. A known mapped downgrade
   is projected even when it creates derived over-limit state, preserves reads,
   and deletes no product membership or report.
10. CI runs Minitest, style, security, eager-load, and PostgreSQL preparation;
    the production image builds and boots.
11. Production runs behind TLS with secrets outside the repository, durable
    PostgreSQL backups, a separate job worker, and actionable billing alerts.
12. The launch checklist in
    [Production MVP Execution Plan](exec_plans/production_mvp.md) is complete.
13. Critical authentication, tenant, membership, assignment, checkout, and
    billing flows are responsive, keyboard-operable, and expose semantic error
    and status feedback.
14. Every `/admin` route denies an ordinary user and organization owner, catalog
    identity fields cannot be changed, catalog mutations are audited, billing
    diagnostics remain read-only and tenant-rooted, and no admin response exposes
    provider secrets or stored diagnostic payloads.
15. The Analytics slice requires its exact server-owned feature and permission
    contract, creates reports within an atomic finite/unlimited organization
    limit, scopes show/export by `Current.organization`, and neutralizes
    spreadsheet-formula prefixes in exported user-controlled cells.
16. Plan-change preflight reports deterministic newest remediation candidates
    without mutation, and exact/unlimited capacity behavior is identical for
    product seats and reports.

## 11. Required product inputs before launch

These inputs do not change the architecture but must be supplied before their
dependent implementation PR:

- Product name and whether the existing `RailsSass`/`rails_sass` identifiers
  are intentional or a `SaaS` naming correction is required.
- Initial production product, feature, role, and permission keys. The local
  Analytics/CRM role and permission seed is synthetic development/test data,
  not a production catalog decision.
- Code-reviewed stable registry key, unit, and authoritative tenant-rooted usage
  query for every limit feature; MVP includes per-product `seat_limit` and
  Analytics `report_limit`.
- Initial plans, plan-product rows, feature entitlement values, local price
  display data, and the Lemon Squeezy test/live variant map.
- Production domain, hosting topology, PostgreSQL service, email delivery
  provider, backup target, and alert destination.
