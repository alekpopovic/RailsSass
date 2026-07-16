# Authorization Model

Status: Proposed
Last updated: 2026-07-16

## 1. Purpose

This document is the normative server-side authorization contract. It combines
path-based tenancy, organization roles, local plan entitlements, product RBAC,
record rules, and numeric capacity. All checks fail closed.

The relational structures are in [Data Model](data_model.md). The canonical
subscription predicate is in
[Billing Model](billing_model.md#8-subscription-access-matrix).

The read-only `Entitlements::Resolver` now implements local subscription status,
effective-plan selection, and typed catalog entitlement results. The application
still has no production subscription writer: only the future verified-webhook
projection may create or change paid local state. Product RBAC and the complete
`Access::Decision` composition remain separate later milestones.

## 2. Security invariants

1. Authentication is necessary but never sufficient for tenant access.
2. A URL slug is routing input, not authorization evidence.
3. Every tenant-owned child query starts from `Current.organization`. Global
   locator infrastructure may select only a candidate tenant and is never
   authorization.
4. Organization role and product access are orthogonal.
5. Product entitlement and product permission are both required.
6. `ProductFeature` and `ProductPermission` are different concepts and keys.
7. Owner/admin/billing/member never bypass product RBAC or entitlements.
8. A product membership without a role grants no permission.
9. A permission without a product membership grants nothing.
10. Missing or disabled entitlement rows and exhausted finite capacity deny the
    applicable action. Unknown/blocked billing state can never grant a paid
    plan; only the explicit active free fallback remains available.
11. UI hiding is never a security boundary.
12. Authorization makes no provider network call and uses no checkout redirect
    parameter.

## 3. Current context

`Current` is an `ActiveSupport::CurrentAttributes` object containing only:

- `user`;
- `session` when needed for audit/revocation;
- `organization`;
- `membership` (the authoritative organization membership; the legacy
  `organization_membership` accessor is a compatibility alias).

Context is established and cleared at request/job boundaries. Domain methods do
not infer a tenant from arbitrary records or a process-global variable.

### 3.1 Ordinary tenant bootstrap

For a tenant request:

1. Authenticate `Current.user`.
2. Normalize `params[:organization_slug]`.
3. Resolve a candidate organization through the authenticated
   user's global `OrganizationAccessLocator` and the normalized slug.
4. Continue only if the candidate organization is active, then set
   `Current.organization` to it.
5. Reload the authoritative active membership through
   `Current.organization.organization_memberships` for `Current.user`, then set
   `Current.membership`.
6. Continue only when the user is enabled and the tenant-owned reload succeeds.

The global locator is a discovery index maintained atomically with membership;
it contains no role authority. A stale locator fails at step 5. Querying
`organization_memberships` globally or treating the locator as membership is
forbidden. Organization switching lists locator candidates, then performs the
same tenant-owned reload before entering one.

### 3.2 Tenant record loading

After bootstrap, use the pattern:

```ruby
record = policy_scope(Current.organization.projects).find(params[:id])
authorize record, :update?
```

Never use `Project.find(params[:id])`, an unscoped association supplied by a
client, or a tenant `default_scope`. Policy scopes and policies also assert
record organization ownership as defense in depth.

Non-member tenant slugs and cross-tenant record IDs return not found. A known
within-tenant record for which the user lacks a capability returns forbidden,
unless disclosure of existence would itself be sensitive.

## 4. Organization authorization

Organization administration does not require a paid product plan. The exact
role matrix is:

| Action | owner | admin | billing | member |
| --- | ---: | ---: | ---: | ---: |
| View organization shell | Allow | Allow | Allow | Allow |
| Update organization name | Allow | Allow | Deny | Deny |
| Invite/manage member or admin | Allow | Allow | Deny | Deny |
| Grant/revoke owner or billing | Allow | Deny | Deny | Deny |
| Manage product memberships/roles | Allow | Allow | Deny | Deny |
| View/manage billing and checkout | Allow | Deny | Allow | Deny |

Additional rules:

- A suspended organization authorizes no tenant access.
- An admin cannot alter an owner or billing membership.
- Membership role/status actions cannot leave zero active owner memberships.
- Account disablement cannot leave zero access-eligible owners (an active owner
  membership plus an enabled user).
- A user cannot accept an invitation for a different normalized email.
- A suspended membership authorizes nothing.
- A disabled user authorizes nothing even if membership rows remain active.
- Membership suspension atomically removes its access locator and product
  memberships/roles; later reactivation requires explicit product reassignment.
- Product usage for every role proceeds through the product gate below.

The Tenancy module exposes the commands as `Organizations::Create`,
`Organizations::Memberships::ChangeRole`,
`Organizations::Memberships::Remove`, and
`Organizations::Memberships::Reactivate`. `Remove` is a soft transition to
`suspended`, never row deletion. All membership commands require
`Current.organization`, reload their target through its membership association,
authorize the actor according to the matrix above, and lock the organization in
the same transaction as the transition. Billing and member actors therefore
cannot manage memberships through a direct service call.

## 5. Product authorization decision

### 5.1 Server-owned action contract

Every product action is registered in code with:

- `product_key` and `permission_key`;
- required `feature_key` when the action is feature-gated;
- whether the action consumes numeric capacity and a server-side delta
  calculator/command;
- the owning product policy/command entry point.

Controllers/clients select an application action, not arbitrary permission,
feature, or delta fields. Omitting a client parameter therefore cannot turn a
consuming action into a non-consuming action. Permission and feature keys are
resolved within the registered product. `now` is injected internally for
deterministic subscription boundaries.

### 5.2 Decision flow

`Access::Decision` is a pure, non-mutating common gate. It grants only when every
applicable step succeeds:

```text
1. authenticated, enabled Current.user
2. active Current.organization
3. active Current.membership for Current.organization
4. resolve an effective local plan: use an accessible current paid
   `Billing::Subscription`, otherwise the one active free plan
5. the effective Plan has a PlanProduct row for the product
6. when feature is required:
   a. PlanFeatureEntitlement exists for that product feature
   b. enabled is true
   c. a flag carries no capacity, or a limit has one valid finite/unlimited
      capacity representation
7. ProductMembership exists for current organization membership and product
8. union of assigned ProductRoles includes the required ProductPermission
```

Any false, null, unknown, malformed, or exceptional result denies. The
Entitlements layer returns an immutable `Entitlements::Result` containing
`allowed?`, a stable internal reason code, paid/free plan source, and
finite/unlimited capacity when applicable. `Access::Decision` later composes
that result with organization and product RBAC. Neither layer measures usage or
mutates product data.

Final server authorization composes three owned layers:

1. `Access::Decision` performs steps 1-8.
2. The product Pundit policy loads the record through `Current.organization`,
   requires the common grant, and applies product-owned record rules.
3. For a consuming action, the product command repeats/revalidates the common
   grant inside its transaction and atomically enforces authoritative usage plus
   the server-calculated delta against the returned limit before mutation.

All three applicable layers must pass. This direction keeps Billing/Catalog/RBAC
inside Access while record rules and capacity remain owned by the product module,
without a module dependency cycle.

### 5.3 Base product actions

An action that is not feature-specific still requires common steps 1-5 and 7-8,
then its product policy. A plan product row does not imply every feature, and a
feature row is not required for the base product shell.

The unique active `Plan.free` row is step 4's deterministic fallback when no
paid subscription is accessible. It does not create or mutate a subscription.
For an existing paid subscription, `Plan.active` and `PlanPrice.active` remain
selection metadata rather than authorization kill switches.

### 5.4 Flag features

- Missing row: deny.
- `enabled = false`: deny.
- `enabled = true`: continue through product membership and permission checks.
- A flag entitlement never has `limit_value` or `unlimited` capacity.

### 5.5 Numeric limits

- A limit entitlement is configured as exactly one of a finite non-negative
  integer or explicit `unlimited = true`, regardless of its enabled state.
- `enabled = false` always denies while retaining the configured capacity.
- `enabled = true, unlimited = true` has no numeric ceiling, but still requires
  every subscription, product-membership, permission, record-policy, and
  transactional command check.
- Finite limits are organization-wide.
- `0` permits no consuming delta but does not inherently block read operations.
- For finite limits, an exact boundary where `usage + delta == limit` is allowed
  and `usage + delta > limit` is denied.
- Downgrade below current usage preserves reads and non-consuming mutations but
  blocks further consumption until usage is reduced or entitlement increases.
- Check and mutation occur under a product-owned lock, conditional update, or
  equivalent database-atomic operation. A preflight UI check is not the final
  authorization.
- Each limit feature has a code-reviewed registry entry defining unit,
  authoritative query/counter, lock strategy, and which actions consume or
  release capacity.

Time-window metering is not part of the MVP.

### 5.6 Entitlements resolver contract

`Entitlements::Resolver` is constructed only for `Current.organization`; a
different organization raises not found. Its stable-key API is:

- `product_enabled?(product_key)` and
  `feature_enabled?(product_key, feature_key)` return booleans;
- `limit(product_key, feature_key)` returns a finite integer (including `0`),
  `:unlimited`, or `nil` when no enabled limit is available;
- `enabled_products` returns sorted stable product keys;
- `explain(product_key:, feature_key: nil)` returns `Entitlements::Result` with
  `allowed?`, `reason_code`, plan key/source, feature kind, and typed capacity.

Representative denial codes are `no_effective_plan`, `product_not_found`,
`product_not_in_plan`, `feature_not_found`, `feature_not_entitled`,
`feature_disabled`, `invalid_limit_configuration`, and the explicit
`subscription_*` matrix codes. `feature_enabled?` fails closed for a missing
feature key. The resolver has no user, membership, ProductRole,
ProductPermission, usage, or provider-HTTP logic.

## 6. Pundit integration

Pundit policies compose the common decision with product-owned record-specific
rules. They do not duplicate the billing matrix, entitlement/RBAC logic, or
SQL-scoping contract.

Controller requirements:

- call `authorize` for member actions;
- use `policy_scope` for tenant collections;
- enable `verify_authorized` and `verify_policy_scoped` in authenticated
  controllers;
- explicitly and narrowly skip verification for health, authentication, and
  the verified webhook ingress where Pundit does not apply;
- perform authorization on direct HTML, Turbo, and JSON requests equally.

The same policy/decision predicate may drive UI visibility. The controller
still re-resolves all submitted IDs and authorizes the resulting action.

## 7. Context establishment boundaries

No tenant-owned child row is queried before `Current.organization` is set.
Candidate tenant discovery uses only the root organization or the two global,
non-authoritative locator tables defined in the data model.

### 7.1 New organization creation

Verified and authenticated `POST /organizations` is global because the tenant
does not exist yet. `Organizations::Create` uses one database transaction to
insert an active organization and its first active owner membership. After a
successful commit, and never before, it sets `Current.organization` and
`Current.membership`. Registration and email verification do not
implicitly invoke the command.

The path-bootstrap migration backfills locators for existing active memberships
before tenant routes are enabled. Organization creation now creates its locator
in the same transaction as the first owner membership, membership suspension
removes its locator in the same locked transaction, and onboarding redirects to
the tenant dashboard. Request-local `Current` never replaces this persistent,
revalidated authorization state.

### 7.2 Authenticated tenant path and switcher

Described in section 3.1. The global account locator selects a candidate; the
authoritative membership is always reloaded through `Current.organization`.

### 7.3 Pre-membership invitation acceptance

The special route `/o/:organization_slug/invitations/accept?token=...` resolves
the public slug to a tentative organization root and sets
`Current.organization` with no membership. The filtered token query parameter
is never part of the route path or a persisted post-login destination. An
unauthenticated recipient signs in or registers and then reopens the email
link. The flow may then query only
`Current.organization.organization_invitations`, compare the token digest, bind
the authenticated normalized email, and validate expiry/state. On success, one
transaction creates/reactivates the membership and access locator. No other
tenant data is exposed before that succeeds; failures return a generic not-found
or invalid-invitation response.

### 7.4 Tenant jobs

A trusted job argument may load only the organization root by ID, set
`Current.organization`, then reload every tenant child through it. Ordinary
tenant jobs fail closed when the root is missing.

A scheduler that fans out tenant work may enumerate organization roots and
enqueue their IDs, but it cannot query tenant-owned children globally. Each
child query occurs inside the per-organization wrapper.

### 7.5 Verified webhook tenant resolution

The global webhook endpoint may resolve a tenant only after raw-body signature
verification, durable idempotent receipt, event/store/environment validation,
and a trusted global `Billing::ProviderLocator` match:

- an existing provider/environment subscription identifier; or
- the SHA-256 digest of a high-entropy, unresolved checkout-attempt token from
  signed webhook custom data.

After discovery, the job sets `Current.organization` and reloads checkout and
subscription rows through that organization before any mutation. It never
resolves by email, name, slug, browser session, or client-provided integer ID.

The locator selects only `organization_id`. The resolver then sets
`Current.organization` and reloads the checkout/subscription through that
organization. The resolver is private to Billing and unavailable to ordinary
controllers and product services.

### 7.6 Global account disablement

Account disablement remains unavailable until a dedicated cross-organization
guard is implemented. That guard enumerates candidate organization roots only
through the user's global access locators, locks those roots in stable ID order,
and for each root sets `Current.organization` before reloading
memberships/access-eligible-owner state through that organization. The service
aborts the entire transaction if any tenant would lose its last access-eligible
owner, then clears context. It never queries memberships globally.

## 8. Background jobs

Ordinary tenant jobs carry `organization_id`, follow section 7.4, clear
`Current`, and call the same service/policy contracts as synchronous code where
appropriate. Pre-tenant webhook jobs carry a verified event ID and follow
section 7.5. Jobs do not inherit request context and do not use stale serialized
tenant objects as authority.

Tests must show that:

- missing/wrong organization denies or fails safely;
- context is cleared between sequential jobs on the same thread;
- a job cannot mutate a record belonging to another organization;
- retries are idempotent.

## 9. Caching and consistency

Final authorization, subscription time decisions, RBAC, record policy, and
usage decisions are not cached across requests. The Entitlements resolver may
cache only its primitive catalog snapshot for 12 hours. The key contains the
effective plan and subscription `cache_key_with_version` plus collection
versions for products, features, plan products, and entitlement rows. A catalog
or subscription update therefore selects a new key, and old generations expire.
Authorization-affecting catalog writers must preserve this contract by updating
`updated_at`; unversioned `update_all`/direct-SQL catalog mutations are
prohibited.

Product membership rows may survive loss of entitlement. They become effective
again only when a later verified webhook restores paid access or a reviewed
catalog change grants the product through the active free fallback. They do
**not** survive organization-membership suspension; that service removes them,
so reactivation requires explicit reassignment.

## 10. Audit requirements

Once the audit-ledger follow-up lands, structured audit events are emitted for:

- organization creation;
- invitation creation/revocation/acceptance;
- membership role/status changes and attempted last-owner violations;
- product membership/role changes;
- checkout initiation;
- tenant-resolved verified-webhook projection outcome and
  subscription/plan/status transitions;
- quarantined billing mappings and administrative repair actions.

Audit output contains stable internal IDs and action codes but excludes
passwords, session tokens, invitation plaintext tokens, API keys, signatures,
raw webhook bodies, portal URLs, and unnecessary PII.

Pre-tenant ingress outcomes cannot be assigned to a tenant `AuditEvent` safely.
Invalid signatures produce bounded security metrics/redacted logs only; signed
unsupported or quarantined envelopes are durably represented by the global
`Billing::WebhookEvent` ledger. A tenant audit row begins only after trusted
provider-locator resolution and tenant reload.

## 11. Test strategy

### 11.1 Organization role table

Table-driven policy tests cover every action/role cell, suspended organization
and membership, disabled user, admin attempts against owner/billing members, and
concurrent last-active-owner membership changes. Account-disable concurrency
cases for the last access-eligible owner land with the locator/path-bootstrap
guard.

### 11.2 Product gate truth table

Start from one allowed composed request/command, then independently remove or
invalidate:

1. authentication;
2. organization active status;
3. organization membership or active status;
4. synchronized/access-granting subscription;
5. plan-product entitlement;
6. feature entitlement/value;
7. product membership;
8. product role;
9. required permission;
10. product-policy tenant record ownership;
11. product-command numeric capacity.

Every variation must deny. Additional positive/negative cases cover multiple
role permission union, identical keys in another product, owner/admin no-bypass,
disabled flag/limit, finite limit zero, explicit unlimited, exact boundary,
over-limit downgrade, and concurrent final-unit consumption. Action-registry tests prove a client cannot omit or
change the required permission, feature, consumption flag, or delta calculator.

Separate unit tests cover the pure common gate, product policy record rules, and
the product command's atomic capacity+mutation transaction; request tests prove
all applicable layers compose.

### 11.3 Request and isolation tests

- A non-member slug and a cross-tenant guessed ID return not found.
- A same-tenant direct POST without permission returns forbidden and changes no
  data, even when its control is absent from the UI.
- Tenant collections never contain another organization's rows.
- `verify_authorized`/`verify_policy_scoped` catch omitted controller checks.
- `Current` resets between requests and after exceptions.
- Billing owner/billing role checks are enforced server-side.

### 11.4 Runtime isolation from billing provider

Authorization and policy tests install a network-call assertion and prove that
no Lemon Squeezy request occurs. Redirect parameters and pending checkout state
cannot affect an access decision.

## 12. Authorization acceptance criteria

- The central product decision is the only shared product gate used by Pundit
  policies.
- Every tenant-owned query in controllers, services, and jobs is visibly rooted
  in `Current.organization`; the section 7 context-establishment paths may use
  only non-authoritative global locators to select a candidate root, then must
  immediately reload tenant-owned rows through that root.
- Organization roles match the canonical matrix exactly.
- Paid subscription eligibility and active-free fallback match the single
  billing matrix exactly.
- Every product action requires entitlement and permission, and owner/admin have
  no bypass.
- Numeric consumption is database-atomic under concurrency.
- Direct requests remain denied regardless of UI state.
