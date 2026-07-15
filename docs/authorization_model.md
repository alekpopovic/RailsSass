# Authorization Model

Status: Proposed
Last updated: 2026-07-15

## 1. Purpose

This document is the normative server-side authorization contract. It combines
path-based tenancy, organization roles, local plan entitlements, product RBAC,
record rules, and numeric capacity. All checks fail closed.

The relational structures are in [Data Model](data_model.md). The canonical
subscription predicate is in
[Billing Model](billing_model.md#8-subscription-access-matrix).

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
10. Missing entitlement rows, boolean false, exhausted numeric capacity for a
    consuming/increasing action, unknown billing state, and mapping/sync errors
    deny.
11. UI hiding is never a security boundary.
12. Authorization makes no provider network call and uses no checkout redirect
    parameter.

## 3. Current context

`Current` is an `ActiveSupport::CurrentAttributes` object containing only:

- `user`;
- `session` when needed for audit/revocation;
- `organization`;
- `organization_membership`.

Context is established and cleared at request/job boundaries. Domain methods do
not infer a tenant from arbitrary records or a process-global variable.

### 3.1 Ordinary tenant bootstrap

For a tenant request:

1. Authenticate `Current.user`.
2. Normalize `params[:organization_slug]`.
3. Resolve a candidate organization through the authenticated
   user's global `OrganizationAccessLocator` and the normalized slug.
4. Set `Current.organization` to that candidate.
5. Reload the authoritative active membership through
   `Current.organization.organization_memberships` for `Current.user`, then set
   `Current.organization_membership`.
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

- An admin cannot alter an owner or billing membership.
- Membership or account-disable actions cannot leave zero eligible owners
  (active owner membership plus enabled user).
- A user cannot accept an invitation for a different normalized email.
- An inactive membership authorizes nothing.
- A disabled user authorizes nothing even if membership rows remain active.
- Membership deactivation atomically removes its access locator and product
  memberships/roles; later reactivation requires explicit product reassignment.
- Product usage for every role proceeds through the product gate below.

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
2. active Current.organization_membership for Current.organization
3. current local Billing::Subscription is synchronized and access-granting now
4. subscription's exact Plan has PlanProductEntitlement for the product
5. when feature is required:
   a. PlanFeatureEntitlement exists for that product feature
   b. boolean value is true, or numeric limit is present
6. ProductMembership exists for current organization membership and product
7. union of assigned ProductRoles includes the required ProductPermission
```

Any false, null, unknown, malformed, or exceptional result denies. The decision
returns a structured grant containing `allowed?`, a stable internal reason code,
and the typed numeric limit when applicable. It does not load product records,
measure usage, or mutate product data.

Final server authorization composes three owned layers:

1. `Access::Decision` performs steps 1-7.
2. The product Pundit policy loads the record through `Current.organization`,
   requires the common grant, and applies product-owned record rules.
3. For a consuming action, the product command repeats/revalidates the common
   grant inside its transaction and atomically enforces authoritative usage plus
   the server-calculated delta against the returned limit before mutation.

All three applicable layers must pass. This direction keeps Billing/Catalog/RBAC
inside Access while record rules and capacity remain owned by the product module,
without a module dependency cycle.

### 5.3 Base product actions

An action that is not feature-specific still requires common steps 1-4 and 6-7,
then its product policy. A plan product row does not imply every feature, and a
feature row is not required for the base product shell.

### 5.4 Boolean features

- Missing row: deny.
- Explicit `false`: deny.
- Explicit `true`: continue through product membership and permission checks.

### 5.5 Numeric limits

- Limits are finite, integer, non-negative, and organization-wide.
- `0` permits no consuming delta but does not inherently block read operations.
- An exact boundary where `usage + delta == limit` is allowed.
- `usage + delta > limit` is denied.
- Downgrade below current usage preserves reads and non-consuming mutations but
  blocks further consumption until usage is reduced or entitlement increases.
- Check and mutation occur under a product-owned lock, conditional update, or
  equivalent database-atomic operation. A preflight UI check is not the final
  authorization.
- Each numeric feature has a code-reviewed registry entry defining unit,
  authoritative query/counter, lock strategy, and which actions consume or
  release capacity.

Time-window metering is not part of the MVP.

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

Authenticated `POST /organizations` is global because the tenant does not exist
yet. One transaction inserts the organization, first eligible owner membership,
and global access locator. It does not query an existing tenant child outside
`Current.organization`; the response redirects to the new tenant path, whose
next request uses ordinary bootstrap.

### 7.2 Authenticated tenant path and switcher

Described in section 3.1. The global account locator selects a candidate; the
authoritative membership is always reloaded through `Current.organization`.

### 7.3 Pre-membership invitation acceptance

The special route `/o/:organization_slug/invitations/:token/accept` resolves the
public slug to a tentative organization root and sets `Current.organization`
with no membership. It may then query only
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

Account disablement may affect several tenants. It enumerates candidate
organization roots only through the user's global access locators, locks those
roots in stable ID order, and for each root sets `Current.organization` before
reloading memberships/eligible-owner state through that organization. The
service aborts the entire transaction if any tenant would lose its last eligible
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

Authorization decisions are not cached across requests in the MVP. This avoids
stale grants after membership, role, plan, or subscription changes. Within one
request, memoization is allowed only when keyed by organization membership,
product, action, feature, and the relevant records' versions/timestamps.

Product membership rows may survive loss of entitlement. They become effective
again only when a later verified webhook restores an access-granting local plan.
They do **not** survive organization-membership deactivation; that service
removes them, so reactivation requires explicit reassignment.

## 10. Audit requirements

At minimum, structured audit events are emitted for:

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

Table-driven policy tests cover every action/role cell, inactive membership,
disabled user, admin attempts against owner/billing members, and concurrent
last-eligible-owner/user-disable changes.

### 11.2 Product gate truth table

Start from one allowed composed request/command, then independently remove or
invalidate:

1. authentication;
2. organization membership or active status;
3. synchronized/access-granting subscription;
4. plan-product entitlement;
5. feature entitlement/value;
6. product membership;
7. product role;
8. required permission;
9. product-policy tenant record ownership;
10. product-command numeric capacity.

Every variation must deny. Additional positive/negative cases cover multiple
role permission union, identical keys in another product, owner/admin no-bypass,
boolean false, limit zero, exact boundary, over-limit downgrade, and concurrent
final-unit consumption. Action-registry tests prove a client cannot omit or
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
- Subscription eligibility matches the single billing matrix exactly.
- Every product action requires entitlement and permission, and owner/admin have
  no bypass.
- Numeric consumption is database-atomic under concurrency.
- Direct requests remain denied regardless of UI state.
