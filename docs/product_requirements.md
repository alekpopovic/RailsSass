# Product Requirements: Modular SaaS MVP

Status: Proposed
Last updated: 2026-07-15

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

The repository is currently a greenfield Rails 8.1.3 skeleton:

- PostgreSQL, Hotwire, Tailwind, Solid Queue, Solid Cache, Solid Cable, Docker,
  and Kamal scaffolding exist.
- No domain models, primary migrations, tenant routes, authentication,
  authorization, billing integration, or tests exist.
- Pundit is not installed and `rails/test_unit/railtie` is disabled.
- CI runs lint and security scans but does not run a PostgreSQL-backed test
  suite.
- Deployment configuration still contains generator placeholders.

The execution plan must not treat any requested domain behavior as already
implemented.

## 3. Product statement

An authenticated user can participate in multiple organizations. Each
organization buys access to a versioned plan. The plan grants products and
typed product features. Organization administrators assign members to specific
products and product roles. A product action is permitted only when both the
organization's local entitlement and the member's product permission allow it.

Lemon Squeezy handles checkout and subscription lifecycle events. The local
PostgreSQL state is the only runtime source for access decisions. A browser
redirect or an outbound provider API response never grants access.

## 4. Personas and roles

### 4.1 User

A global account that can authenticate and hold memberships in multiple
organizations. A user has no tenant access without an active organization
membership.

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
| Use an entitled product | Product gate | Product gate | Product gate | Product gate |

Multiple owners are allowed, but every organization must retain at least one
eligible owner: an active owner membership whose user is enabled. No
organization role bypasses product membership, product permission, or plan
entitlement.

### 4.3 Product roles

Product roles are system-defined per product. A product membership can have
multiple product roles; its effective permission set is their union. The MVP
has no explicit deny permission and no tenant-defined custom roles.

## 5. Immutable product invariants

1. Every ordinary tenant URL is under `/o/:organization_slug/`, except global
   account/organization creation, health, authentication, and provider webhook
   routes.
2. Ordinary tenant context selects a candidate through a non-authoritative
   account locator, then verifies the active membership through
   `Current.organization`; a slug/locator alone never authorizes.
3. After a candidate root is set, every tenant-owned child query is rooted at
   `Current.organization`.
4. Organization role and product RBAC are independent.
5. Product access requires an access-granting local subscription, plan product
   entitlement, product membership, and product permission.
6. A feature-specific action additionally requires the typed feature
   entitlement. A consuming numeric action additionally requires capacity.
7. Missing, malformed, stale-conflicted, or unknown authorization input denies
   access.
8. UI visibility is advisory; every read and mutation is authorized on the
   server.
9. Runtime authorization makes no Lemon Squeezy API call.
10. Only processing rooted in a verified, durably stored, idempotent webhook
    may change local subscription state.

## 6. MVP scope

### 6.1 Identity and tenancy

- Email/password authentication, logout, session revocation, and password
  reset using Rails-native primitives.
- Organization creation with a globally unique, normalized, immutable slug.
- Organization switcher for users with multiple active memberships.
- Email invitation flow with an expiring, single-use token. An invitation does
  not authorize access before acceptance.
- Organization membership management according to the role matrix.
- Safe owner transfer/demotion/removal that cannot leave an organization
  without an eligible owner, including concurrent membership/account-disable
  requests.
- Membership deactivation revokes its product assignments; later reactivation
  requires explicit product reassignment.

### 6.2 Catalog and plans

- System-managed global `Product`, `ProductFeature`, `Plan`, product role, and
  product permission catalogs.
- Stable product, feature, role, and permission keys in English.
- Versioned plans. Published plan versions and their entitlements are
  immutable; changing an offering creates a new plan version.
- Retiring a plan blocks new price mappings/checkouts but does not revoke the
  immutable version from already synchronized subscriptions.
- A plan-product entitlement row grants base product access.
- Product features are either boolean or finite non-negative integer limits.
- Missing feature entitlement denies the feature. Boolean `false` denies it.
- Numeric limits apply per organization. Each consuming product action defines
  its unit and authoritative organization-scoped usage query.
- Reaching a numeric limit blocks only consuming/increasing operations; reads
  and non-consuming operations remain available.

### 6.3 Product access management

- Owner/admin can add an active organization member to an entitled or
  non-entitled product and assign one or more system product roles.
- Assignments may remain dormant after a downgrade or subscription loss; they
  do not grant access until the entitlement gate is true again.
- Dormancy does not apply to membership removal: deactivation destroys the
  member's product assignments.
- Product policies use one central decision service for the shared
  entitlement-and-permission gate, then apply record-specific rules.
- Cross-organization record identifiers never expose or mutate another
  organization's data.

### 6.4 Billing

- Server-side checkout creation for an allowlisted local billing price.
- Only owner/billing may initiate checkout or open provider subscription
  management.
- At most one current non-superseded subscription and one pending checkout per
  organization.
- Only verified `expired` is terminal for replacement checkout; a new verified
  subscription atomically supersedes the expired historical row.
- Checkout return page displays local `pending` or synchronized state; it does
  not mutate billing or entitlement records.
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

### 6.5 User experience

- Server-rendered Hotwire/Turbo flows with focused Stimulus controllers.
- Tailwind-based responsive pages for authentication, organization switching,
  membership administration, product assignments, subscription status, and
  checkout pending/success/error states.
- Accessible forms, validation messages, keyboard navigation, and clear 403,
  404, and billing-pending states.
- UI controls use the same permission predicates for presentation while the
  server independently enforces every request.

### 6.6 Production operations

- PostgreSQL-backed CI and Minitest coverage before behavioral work lands.
- Separate web and Solid Queue worker processes for production billing jobs.
- Docker image build, eager-load, migration, and boot smoke checks.
- Kamal-ready configuration without committed secrets or provider credentials.
- TLS, allowed-host policy, secure cookies, structured/redacted logs, database
  backups, restore drill, queue monitoring, and webhook failure alerts.

## 7. Primary user journeys

### 7.1 Create and enter an organization

1. An authenticated user creates an organization and becomes its first owner.
2. The application normalizes and reserves its immutable slug.
3. The user enters `/o/:organization_slug/`; tenant context is established
   through the new active membership.
4. Without an access-granting subscription, organization administration and
   billing remain available, but product actions deny.

### 7.2 Invite and assign a member

1. Owner/admin creates an invitation within `Current.organization`.
2. The recipient authenticates and accepts the unexpired token.
3. Acceptance atomically creates or reactivates one membership for that user
   and organization.
4. Owner/admin creates a product membership and assigns product roles.
5. The member can act only if the plan and product permission gates also pass.

### 7.3 Subscribe

1. Owner/billing selects an active local billing price.
2. The server creates a tenant-scoped checkout attempt and a provider checkout.
3. The browser returns to a pending page after payment.
4. A valid Lemon Squeezy webhook is verified and durably recorded.
5. Webhook ingress hashes signed custom token data and persists only its digest.
   Background processing uses that digest to resolve only a global
   non-authoritative provider locator, establishes
   `Current.organization`, validates tenant/provider mappings, and updates the
   local subscription in a transaction. Plaintext token is never persisted.
6. Subsequent requests resolve the exact local plan version; no request calls
   Lemon Squeezy for authorization.

### 7.4 Consume a limited feature

1. The request establishes tenant and organization membership context.
2. The common gate verifies subscription, plan product, feature, product
   membership, and permission.
3. The product command revalidates the common grant, locks or atomically checks
   its authoritative usage, and applies its server-calculated delta only when it
   remains within the local limit.
4. Concurrent requests cannot both consume the same final unit.

## 8. Non-goals

- Multiple billing providers, one-time purchases, usage-based provider billing,
  coupons, tax calculation, invoice accounting, or a custom payment UI.
- Runtime provider lookups, access changes from redirects, or access changes
  from unverified/manual database edits.
- Free plans, manual entitlement grants, trials not represented by Lemon
  Squeezy, or multiple simultaneous subscriptions per organization.
- Tenant-defined products, plans, roles, permissions, or arbitrary policy
  scripting.
- Explicit deny permissions, resource-level ACL sharing, or organization role
  bypasses for product access.
- SSO/SAML, SCIM, social login, MFA, passkeys, or enterprise identity lifecycle.
- Custom domains, subdomain tenancy, database-per-tenant, or row-level security
  in the MVP.
- Metered/rolling usage windows and provider-reported usage. Numeric MVP limits
  are local finite capacity limits.
- A global back-office catalog editor. Catalog changes ship through reviewed,
  idempotent application data tasks.
- User file uploads unless a concrete product module requires them; local
  Active Storage is not accepted as durable production storage.
- Concrete product-domain functionality beyond the thin vertical slice needed
  to prove the platform authorization contract.
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

1. A user can authenticate, join multiple organizations, and switch tenants.
2. A guessed organization slug or tenant record ID cannot cross tenant
   boundaries.
3. The organization role matrix is server-enforced, including the last-owner
   invariant.
4. A user with an organization role but no product membership/permission is
   denied product access, including owner/admin.
5. A product member with permission but no plan entitlement is denied.
6. Boolean and numeric feature decisions behave as documented, including an
   atomic numeric boundary under concurrency.
7. All subscription status and time-boundary cases match the canonical billing
   matrix.
8. A checkout redirect, outbound API success, duplicate webhook, stale webhook,
   unknown variant, and unknown status cannot over-grant access.
9. A valid webhook can activate, change, cancel, recover, and expire a local
   subscription without a runtime provider dependency.
10. CI runs Minitest, style, security, eager-load, and PostgreSQL preparation;
    the production image builds and boots.
11. Production runs behind TLS with secrets outside the repository, durable
    PostgreSQL backups, a separate job worker, and actionable billing alerts.
12. The launch checklist in
    [Production MVP Execution Plan](exec_plans/production_mvp.md) is complete.
13. Critical authentication, tenant, membership, assignment, checkout, and
    billing flows are responsive, keyboard-operable, and expose semantic error
    and status feedback.

## 11. Required product inputs before launch

These inputs do not change the architecture but must be supplied before their
dependent implementation PR:

- Product name and whether the existing `RailsSass`/`rails_sass` identifiers
  are intentional or a `SaaS` naming correction is required.
- Initial product, feature, role, and permission keys.
- Unit and authoritative usage query for every numeric feature.
- Initial immutable plan versions and the Lemon Squeezy test/live variant map.
- Production domain, hosting topology, PostgreSQL service, email delivery
  provider, backup target, and alert destination.
