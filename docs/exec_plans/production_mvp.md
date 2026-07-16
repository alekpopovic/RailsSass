# Production MVP Execution Plan

Status: In progress
Last updated: 2026-07-16
Owner: Engineering

## 1. Objective

Deliver the Rails modular-monolith SaaS MVP defined by:

- [Product Requirements](../product_requirements.md)
- [Architecture](../architecture.md)
- [Data Model](../data_model.md)
- [Authorization Model](../authorization_model.md)
- [Billing Model](../billing_model.md)
- [Security Model](../security_model.md)
- [ADR 0001](../adr/0001-modular-monolith.md)
- [ADR 0002](../adr/0002-local-entitlements.md)
- [ADR 0003](../adr/0003-path-based-tenancy.md)

This plan is intentionally split into small, sequential PRs. Each PR must leave
`main` deployable, add tests for every behavior it introduces, and avoid relying
on a later PR to make an insecure endpoint safe.
It is also the living checkpoint record for slices already implemented in the
repository; later work must re-audit those checkpoints rather than assuming the
original plan was followed perfectly.

## 2. Locked decisions

Implementation PRs may not silently change these decisions:

- Rails 8.1, PostgreSQL, Hotwire, Tailwind, Pundit, Solid Queue, and Minitest.
- One modular-monolith codebase and release artifact.
- Tenant UI under `/o/:organization_slug/`.
- All tenant-owned child queries explicitly rooted in `Current.organization`;
  global locator infrastructure selects only a candidate root and never
  authorizes.
- Organizations have database-generated public UUIDs, immutable normalized
  slugs, and `active`/`suspended` status; memberships use
  `active`/`suspended` status and retain their original `joined_at`.
- Organization roles: owner/admin/billing/member with the canonical matrix.
- Tenancy owns `Organizations::Create`, invitation commands, and
  `Organizations::Memberships::{ChangeRole,Remove,Reactivate}`; `Remove`
  soft-suspends and never deletes a membership row.
- Owner/admin have no product-access bypass.
- Billing organization membership is ineligible for product-data access; it
  remains eligible only for the documented billing surface.
- Product access requires an effective local plan (accessible paid subscription
  or active free fallback) AND plan entitlement AND product
  membership/permission.
- Catalog plans use globally unique stable keys, explicit active/free/display
  metadata, and typed plan-product/feature rows. The one active `Plan.free` row
  is the deterministic fallback and never mutates subscription state.
- Limit entitlements use an explicit finite non-negative value or explicit
  unlimited state; `enabled` remains the master grant switch.
- `PlanPrice` is local catalog/display data, not payment proof or an access
  grant. Exact test/live provider mapping remains a required Billing boundary
  before checkout or webhook projection.
- Only verified `expired` is terminal for replacement checkout; resubscription
  atomically supersedes the expired historical row.
- Local database is runtime authorization truth; runtime performs no Lemon
  Squeezy call.
- Redirect/API command success never grants access.
- Only verified-webhook-rooted processing mutates local subscription state.
- Canonical subscription matrix is defined only in
  [Billing Model](../billing_model.md#8-subscription-access-matrix).
- Global catalog/roles/permissions are system-managed. Nullable
  organization-role scope is supported relationally, but tenant-custom catalog
  and a customer-facing custom-role builder are out of scope.
- Internal `/admin` routes require a live database-backed `platform_admin` role;
  organization ownership never substitutes. Public parameters never accept
  `system_role`, and the first admin is promoted by the explicit verified-user
  Rake task.
- Platform-admin catalog writes preserve stable identity, use deactivate/disable
  rather than hard delete, and create append-only global audit evidence in the
  same transaction. Billing diagnostics are read-only; subscription children
  require one exact organization `public_id`, no global organization dropdown,
  `Current.organization` scope, and at most 100 rows per index page.
- The common Access gate is pure entitlement+RBAC; product policies own record
  rules and product commands own atomic capacity/mutation via server action
  contracts.
- The Analytics reference contract uses stable feature keys `dashboards`,
  `custom_reports`, `csv_export`, and `report_limit`, and the five exact action
  mappings documented in the authorization model. One report creation consumes
  one organization-wide `report_limit` unit.

A change to one of these requires an ADR/document update before or in the same
PR as implementation.

## 3. Current-state audit

Observed on 2026-07-16:

- The tracked Rails 8.1.3 application runs on Ruby 4.0.5 with PostgreSQL,
  Hotwire/importmap, Tailwind, Pundit, and Solid Queue/Cache/Cable.
- PostgreSQL-backed local and GitHub Actions quality gates run Minitest, system
  tests, RuboCop, dependency audits, Zeitwerk, and Brakeman.
- Rails-native email/password authentication, server-side sessions, email
  verification, password reset, and explicit organization onboarding exist.
- Organization and membership constraints, the deferred active-owner trigger,
  global access locators, path tenant bootstrap, organization shell, switcher,
  and base Pundit role policies exist.
- Organization invitations, audited member role/suspension/reactivation
  commands, digest-only invitation tokens, and pre-membership acceptance exist.
- The constrained local catalog, development/test seed command, typed
  entitlements, local plan prices, and an audited platform-admin mutation surface
  exist. A DB-authoritative internal admin policy, explicit promotion task, and
  Tailwind `/admin` catalog/diagnostic UI are available to platform admins only.
- A Billing persistence/client foundation exists: tenant customers, checkout
  attempts, subscriptions with archival history, plan-change commands, a
  provider-wide minimal webhook-event ledger, and a fixed-origin Lemon client.
  It has no checkout/webhook controller, mapping/locator, verified projection,
  or writer. A read-only Entitlements status/catalog resolver now uses current
  local subscriptions and the active free fallback without provider I/O.
- Product-role/permission and tenant product-assignment persistence now exist,
  including transactional assignment commands and constrained synthetic local
  seeds. The central ordered `Access::Gate`, live permission checker, immutable
  decision result, shared Pundit helpers, and product-membership management
  policy also exist. The customer shell now provides dashboard, product and
  pricing catalogs, member/product assignment, local-only billing overview,
  organization settings, and profile pages. The Analytics reference slice adds
  tenant-owned reports, exact feature/permission action mappings, atomic
  report-limit enforcement, and CSV export. Billing synchronization, checkout,
  portal actions, and production hardening remain unimplemented.
- Kamal uses placeholder hosts/registry and does not yet supply the database
  configuration expected by production.

Each remaining milestone must re-audit the implemented behavior and may not
claim an invariant without executable evidence.

## 4. External inputs and decisions

Resolve each input by the listed deadline; do not embed a guessed production
value in code.

| Input | Required before | Safe default for planning |
| --- | --- | --- |
| Whether `RailsSass`/`rails_sass` naming is intentional or should be `SaaS`/product-specific | PR-00 | Preserve current identifiers until explicitly decided |
| Initial production product, feature, permission, and role keys | PR-07 | Keep the reviewed Analytics/CRM seed synthetic and local-only until production inputs are approved |
| Numeric feature units and authoritative usage queries | PR-15 | Analytics report creation consumes one unit and counts tenant-owned reports; other production units remain unapproved |
| Initial plan-product rows and feature entitlement values | PR-08 | Synthetic development/test fixtures until product approval |
| Test/live Lemon variant mappings | PR-11/PR-16 | Test mappings only outside production |
| Production host, registry, PostgreSQL, backup target, and alert destination | PR-20 | No deploy |
| Email delivery provider/from-domain | PR-06 | Test delivery only |
| Legal/privacy retention approval | PR-18A | Minimize collection; proposed retention in security doc |

## 5. Delivery rules for every PR

1. Read `AGENTS.md` and affected docs first.
2. Re-audit overlapping implementation, migrations, tests, and git status.
3. State a short PR plan and the invariant being added.
4. Keep schema + behavior + tests coherent; do not add an insecure placeholder
   endpoint that later becomes safe.
5. Add foreign keys, required unique indexes, and check constraints with the
   table migration.
6. Scope all tenant data through `Current.organization`; add negative two-tenant
   tests with the first tenant behavior.
7. Add server-side Pundit authorization for every UI/request behavior.
8. Use synthetic data and local test secrets only.
9. Run and report only commands actually executed.
10. Update affected docs/ADR when implementation discovers a contract change.
11. Include forward deploy, rollback, and data compatibility notes.
12. Do not combine unrelated refactoring or styling.

## 6. Milestone and PR map

| Milestone | PRs | Exit outcome |
| --- | --- | --- |
| 0. Baseline | PR-00 | Reviewable, secret-safe repository and accepted docs |
| 1. Executable foundation | PR-01–02 | Rails/Minitest/system/PostgreSQL CI and boundary check are green before domain behavior |
| 2. Accounts and tenancy | PR-03–06 | Authentication, organizations, scoped routing, invitations and role policies |
| 3. Catalog and RBAC data | PR-07–10 | Stable typed plan graph and constrained product assignments |
| 4. Billing synchronization | PR-11–14B | Signed durable webhook projection and canonical local subscription state |
| 5. Runtime access and checkout | PR-15–17 | Full entitlement+permission gate, atomic limit slice, safe checkout/portal UX |
| 6. Security and production | PR-18A–20 | Hardened app, operable Kamal/PostgreSQL topology, launch evidence |
| 7. Acceptance | PR-21 | End-to-end production MVP criteria demonstrated |

## 7. Detailed PR sequence

### PR-00: Establish repository baseline and documentation

**Goal:** create a reviewable starting point without application behavior.

Scope:

- Confirm the generated Rails skeleton is intentional and record the naming
  decision before durable class/database/deploy identifiers multiply.
- Track the clean generator baseline and the ten architecture/planning documents.
- Audit `.gitignore`, Docker context, Kamal files, and credentials by filename;
  do not expose values.
- Ensure `config/master.key`, environment files, local storage/logs, and any
  populated secret file remain untracked. If `.kamal/secrets` contains anything
  but safe lookup/template logic, replace it with a value-free example and keep
  the real file ignored.
- Document that there are no migrations/tests/domain behaviors yet.

Checks/acceptance:

- Secret scan and `git ls-files` prove no key/real credential is tracked.
- Markdown links and formatting checks pass.
- Fresh clone contains only synthetic/generator data.
- No application behavior, migration, or provider configuration is introduced.

Rollback: revert documentation/baseline files; there is no data effect.

### PR-01: Restore an executable Rails/Minitest foundation

Depends on: PR-00.

**Goal:** make behavioral work test-first and locally executable.

Scope:

- Install locked dependencies and verify the declared Ruby/Rails toolchain.
- Enable `rails/test_unit/railtie` and Minitest generators.
- Add `test/test_helper.rb` and empty model/request/job/policy/system test
  structure as needed, with parallel-test/database behavior explicitly chosen.
- Re-enable Rails system tests and add the required Capybara/browser driver;
  critical system flows are mandatory, not an optional later choice.
- Add Pundit and its base policy/scoping structure, but no tenant policy yet.
- Add `test/architecture/module_boundaries_test.rb` with the documented allowed
  dependency map and a lightweight forbidden-reference check; each later module
  PR extends its fixtures/contract.
- Add `bin/rails zeitwerk:check` and `bin/rails test` to `config/ci.rb`.

Migrations: none.

Tests/checks:

- `bundle check`
- `bin/rails --version`
- `bin/rails db:prepare`
- `bin/rails test`
- `bin/rails test:system`
- `bin/rails zeitwerk:check`
- existing RuboCop/Brakeman/audit commands

Acceptance: a fresh environment can prepare PostgreSQL and run known unit,
request, architecture, and system Minitests; failures are not hidden by an
empty/disabled task.

Rollback: remove foundation configuration/dependencies; no business data.

### PR-02: Add PostgreSQL-backed CI and image smoke

Depends on: PR-01.

**Goal:** require executable evidence on every PR.

Scope:

- Add an ephemeral PostgreSQL service and synthetic CI credentials.
- Run database prepare, Minitest, eager-load/zeitwerk, RuboCop, Brakeman,
  Bundler Audit, and Importmap audit.
- Add a production Docker build smoke. Add web boot smoke without real
  credentials by using safe dummy build/runtime values where Rails supports it.
- Cache dependencies without caching secrets or database state.
- Pin/review third-party CI action versions.

Migrations: none.

Tests/checks: run the workflow locally where supported or validate each command
in the same container/toolchain. CI must fail if the test task is missing or has
load errors.

Acceptance: required checks are green on the baseline and a deliberately failing
test proves the test job is enforced before the PR is finalized.

### PR-03: Add account authentication and session lifecycle

Depends on: PR-02.

**Goal:** establish secure global user identity before tenant routing.

Scope:

- Use Rails-native authentication primitives for registration, email
  verification, `User`, `Session`, login, logout, password reset, and account
  disable checks. Registration creates no organization or membership.
- Add a required non-blank `name`; normalize `email_address`; add password
  digest, nullable `email_verified_at`, and `system_role` with a database-backed
  `user`/`platform_admin` allowlist and default `user`. Keep public identity
  parameters role-free; the later controlled-catalog milestone owns the internal
  admin surface.
- Deny session creation to unverified or disabled users with the same generic
  response used for unknown email and wrong password.
- Use separate, state-bound Rails signed tokens: password reset expires after
  15 minutes and email verification after 24 hours. A successful mutation
  invalidates its token. Token-bearing `GET` actions render confirmation only;
  CSRF-protected `PATCH` actions mutate state, and query/form token parameters
  are filtered from logs.
- Store server-side sessions for 30 days using only a unique SHA-256 digest of
  an opaque raw cookie token. Rotate sessions on login and revoke them on
  logout, password reset, disablement, and security-sensitive changes.
- Keep account routes outside `/o/:organization_slug`.
- Validate post-login redirects as internal application locations with a fixed
  fallback. Add generic non-enumerating authentication/recovery responses and
  enforce endpoint-specific registration/login/reset/verification rate limits.
- Ship responsive Tailwind authentication/reset forms with semantic labels,
  keyboard operation, focus handling, and clear inline/error-summary feedback.
- Add concrete nullable `disabled_at` and deny disabled authentication. Do not
  expose account disable mutation until PR-05 adds the cross-organization
  access-eligible-owner guard.

Migrations:

- `users`: non-blank name, unique normalized email, non-blank/normalization
  checks, password digest, nullable `email_verified_at`, non-null `system_role`
  defaulting to `user` with an allowed-values check, and nullable `disabled_at`.
- `sessions`: non-null user FK with `ON DELETE CASCADE`, user index, unique
  constrained SHA-256 token digest, and non-null expiry.

Tests:

- database constraints, role default/allowlist, and duplicate/case-normalized
  email;
- registration without organization creation and email verification;
- login/logout/session rotation/revocation/expiry;
- unverified and disabled user denial with generic responses;
- reset and verification expiry/single use/non-enumeration plus redacted query
  and form token logs;
- safe internal post-login redirect and malicious redirect fallback;
- endpoint-specific authentication rate limits;
- CSRF and secure cookie configuration behavior;
- system test for keyboard-only registration/login/reset/verification and
  responsive error presentation.

Acceptance: a verified enabled user can establish `Current.user`; registration
creates no organization, and authentication alone grants no organization
access. Raw session/reset/verification tokens are neither persisted nor logged.

### PR-04: Add organizations and membership invariants

Depends on: PR-03.

**Goal:** create the tenant root and organization role source of truth.

Scope:

- Add `Organization`, `OrganizationMembership`, and the `Current` organization
  attributes needed by tenant services. Organization has a database-generated
  unique `public_id` UUID, name, immutable normalized slug, and
  `active`/`suspended` status defaulting to active. Membership has one role,
  `active`/`suspended` status, and non-null `joined_at`.
- Add the Tenancy-owned `Organizations::Create`,
  `Organizations::Memberships::ChangeRole`, and
  `Organizations::Memberships::Remove` commands. `Remove` is soft suspension;
  role changes and removal do not delete membership history.
- Add verified-and-authenticated global onboarding. Registration and email
  verification continue to create no organization automatically.
- In one database transaction, `Organizations::Create` creates the organization
  and its first active owner membership. Set `Current.organization` and
  `Current.membership` only after the outermost commit; a rollback
  must preserve the previous context.
- Require membership mutations to resolve targets through
  `Current.organization.organization_memberships`, enforce the complete role
  matrix (including billing/member denial), lock the organization, and reject
  sequential or concurrent changes that would leave no active owner membership.
- Enforce the same active-owner invariant for direct database writes with a
  deferred constraint trigger that locks the organization root at commit. Use
  the SQL primary schema dump so clean schema loads retain the trigger.
- Keep slug immutable. Organization suspension is represented, but no suspension
  endpoint is added here; archive/hard deletion remains outside the MVP.
- Do not add `OrganizationAccessLocator`, tenant paths, account disablement, or
  `AuditEvent` in this change. They are explicit follow-ups below, not behavior
  that may be claimed by PR-04.

Migrations: organization and membership tables; organization/user FKs, unique
public UUID, slug, and organization/user identities, role/status/slug/nonblank
checks, non-null `joined_at`, lookup indexes, explicit delete behavior, and the
deferred active-owner constraint trigger.

Tests:

- model/database constraint suite;
- multiple owners allowed;
- final active owner cannot be demoted, soft-suspended, or deleted by sequential,
  concurrent, service, or direct database transitions;
- owner/admin/billing/member service matrix, including admin denial for
  owner/billing targets and billing denial for all membership management;
- cross-tenant target IDs cannot escape `Current.organization`;
- organization and first owner creation are atomic, UUID/slug normalization is
  database-backed, and `Current` is assigned only after a successful commit;
- verified/authenticated onboarding succeeds while unverified, unauthenticated,
  and duplicate-slug attempts create no tenant state.

Acceptance: verified authenticated users can explicitly onboard and services can
create and safely administer tenant roots. Request-local `Current` is available
after successful creation, but no `/o/:organization_slug/` URL is accessible
until PR-05 has installed and backfilled locator/bootstrap state.

### PR-05: Add path tenant context, organization shell, and Pundit enforcement

Depends on: PR-04.

Implementation status: the locator migration/backfill, request context,
read-only shell routes, switcher, and base policies are implemented. The
account-disable guard, tenant job wrapper, and any organization update mutation
remain required before the full PR-05 acceptance claim.

**Goal:** make `/o/:organization_slug/` the safe tenant boundary.

Scope:

- Add `OrganizationAccessLocator`, then backfill one locator for every existing
  active membership before enabling any tenant path. Deploy ordering must make
  partial backfill fail closed and must not expose `/o/:organization_slug/`
  until the backfill and constraints complete.
- Extend membership activation/suspension transactions to create/remove locators
  atomically. Locator presence remains discovery only.
- Add request reset lifecycle for the PR-04 `Current` attributes and change
  successful onboarding to redirect to the ordinary tenant path.
- Add path-scoped show/update routes, organization switcher, and base Pundit
  policies.
- Build the organization shell/switcher with responsive Tailwind layout,
  keyboard-visible focus, semantic navigation, and clear 403/404 states.
- Resolve a candidate through the authenticated user's global access locator,
  require an active organization, set `Current.organization`, then reload the
  active membership through that organization before any tenant child query.
- Add the global account-disable ownership guard now that locator discovery is
  available: enumerate only locator candidates, lock organization roots in
  stable ID order, reload access-eligible-owner state through each
  `Current.organization`, abort globally if one tenant would lose its last
  access-eligible owner, and revoke sessions only on success.
- Enable `verify_authorized`/`verify_policy_scoped` with reviewed global-route
  exclusions.
- Add a reusable tenant job context wrapper.

Migrations: access-locator table with organization/user/composite membership FKs,
unique locator identities, supporting lookup indexes, explicit delete behavior,
and a reversible/backward-compatible active-membership backfill. Add no tenant
route until this migration/backfill has completed successfully.

Tests:

- two users/two organizations: non-member slug 404 and no cross-tenant leakage;
- organization role matrix for shell/update and suspended organization denial;
- stale/mismatched locator and global-switcher candidate cannot authorize;
- active membership backfill is complete/idempotent and locator transitions are
  atomic with later membership activation/suspension;
- final access-eligible owner cannot be account-disabled by
  sequential/concurrent calls across one or multiple organizations; successful
  disable revokes sessions and retained locators still authorize nothing;
- direct POST denied regardless of hidden UI;
- `Current` reset after success, exception, and sequential job execution;
- route helpers always carry explicit slug.
- system test covers keyboard organization switching and narrow viewport.

Acceptance: every ordinary tenant request has verified
user+membership+organization context before any tenant-owned child query.

### PR-06: Add invitations and membership administration

Depends on: PR-05 and email-provider choice for production configuration.

**Goal:** provide production-usable member onboarding and role management.

Scope:

- Add the append-only `AuditEvent` table/service before exposing invitation and
  membership-administration mutations. Begin auditing organization creation and
  membership transitions from this rollout; do not fabricate retroactive audit
  rows for PR-04 operations.
- Add `OrganizationInvitation`, creation/revocation/acceptance services, mailer,
  and responsive, keyboard-operable Hotwire/Tailwind administration UI with
  accessible validation/status messages.
- Owner may manage all roles; admin may manage member/admin only and cannot alter
  owner/billing memberships.
- Bind acceptance to authenticated normalized email; token is expiring,
  single-use, and stored as a digest.
- Use the special slug-scoped pre-membership flow: set the tentative
  `Current.organization`, query only its invitation association, then verify
  token digest/email/state/expiry.
- Acceptance creates or reactivates the unique membership and access locator
  atomically. Enforce invitation-create and acceptance rate limits in this PR.

Migrations: audit-event and invitation tables with tenant/actor/inviter composite
FKs, append-only audit shape constraints, unique invitation token digest,
status-based pending-email uniqueness, and role/status/timestamp checks.

Tests:

- exact role matrix and direct requests;
- guessed/expired/revoked/reused/wrong-email token denial;
- concurrent accept creates one membership;
- stale locator and candidate slug/token mismatch expose no tenant data;
- cross-tenant invite/member ID isolation;
- mail contains no secret in logs and uses correct explicit tenant URL;
- keyboard/narrow-viewport invitation administration and accessible validation
  status in a system test.

Acceptance: an owner/admin can onboard allowed roles without any pre-created
production user data.

### PR-07: Add the local product and plan catalog

Depends on: PR-02; initial catalog keys decided before production data task.

**Goal:** establish stable global catalog identities and database-enforced plan
typing without tenant or billing behavior.

Scope:

- Add `Product`, `ProductFeature`, `Plan`, `PlanProduct`,
  `PlanFeatureEntitlement`, and `PlanPrice`.
- Add deployment-controlled, idempotent catalog data task using synthetic
  development/test values and separately supplied production identifiers.
- Seed only the requested synthetic local identities: products `core`,
  `analytics`, and `crm`, plus plans `starter` and `professional`; do not invent
  feature, entitlement, price, or production Lemon values.
- Use stable lowercase keys and active flags; use display names only for
  presentation.
- Treat `Plan.free` as the system fallback class and enforce at most one active
  free plan; it never creates or mutates a subscription.
- Enforce same-product feature attachment with composite foreign keys.
- Model flag entitlements through `enabled`. Model limit capacity as exactly one
  finite non-negative value or explicit unlimited state regardless of enabled;
  enabled remains the grant switch. Settings must be a JSON object.
- Store local monthly/yearly price display data and optional all-or-none Lemon
  identifiers in `PlanPrice`; do not expose checkout or treat it as a complete
  test/live mapping.

Migrations: all six catalog tables with restricted FKs, exact snake-case key
checks, globally unique product/plan keys, per-product feature keys,
plan-product/feature uniqueness, composite product/type FKs, typed
finite/unlimited checks, settings JSON shape, one-active-free partial unique,
price interval/currency/amount checks, and partial Lemon variant uniqueness.

Tests:

- duplicates and invalid keys/kinds/typed capacities/settings/prices fail at DB;
- cross-product and feature-kind mismatch fail at DB;
- only one free plan may be active, including under concurrent writes;
- `PlanPrice` and free/active flags create no tenant/subscription rows and cannot
  authorize a product action by themselves; `active AND free` only selects the
  documented runtime fallback, which still requires plan-product/feature rows
  and later RBAC;
- data task is repeatable.

Acceptance at this checkpoint: catalog reads are global/read-only to tenant
users; a later controlled-mutation milestone must authorize any global admin UI.

### PR-08: Add catalog query and controlled mutation boundaries — implemented checkpoint

Depends on: PR-07.

**Goal:** expose deterministic Catalog-owned reads and reviewed mutation paths
without coupling the catalog to tenant or provider state.

Implementation update (2026-07-16): `Entitlements::Resolver` supplies the
read side. `Platform::PersistCatalog` now owns transactional create/update/
deactivate commands and writes an append-only `Platform::AuditEvent`. The
DB-authoritative `PlatformAdminPolicy`, explicit
`platform_admin:promote[email]` task, and internal Tailwind UI expose only this
reviewed boundary. Read-only subscription diagnostics require explicit
organization `public_id` input without a global organization dropdown and a
tenant-rooted reload; failed webhook events remain a global-ledger view. Both
indexes return at most 100 rows per page.

Scope:

- Add a catalog query returning product/feature entitlement for an exact stable
  plan key/record.
- Return enabled flag or enabled finite/unlimited capacity deterministically;
  missing or disabled rows deny.
- Route catalog creation/update/deactivation through one service that records an
  append-only global audit event in the same transaction. Product, feature,
  plan, and price use deactivation instead of hard delete; plan-product is
  create-only; entitlements preserve identity and disable with `enabled=false`.
- Require an active plan and product for a new plan-product, an active plan for a
  new plan-price, and an active plan, product, and feature for a new entitlement,
  using one composite stable feature identity. Deactivation retains existing
  catalog and billing-history relationships but blocks new ones. Keep
  entitlement settings out of the web UI and filtered from request logs. Once
  billing history references a price, permit only active-status changes and
  require a new price for commercial/mapping changes.
- Require the live PostgreSQL `platform_admin` role for every `/admin` route.
  Keep `system_role` out of public parameters and bootstrap the first admin only
  with the normalized-email task after verified/enabled checks.
- Keep billing views diagnostic-only: accept one exact organization `public_id`,
  load no global organization dropdown, and read its subscriptions through
  `Current.organization`; show only failed global webhook events; bound both
  indexes to 100 rows per page; render no payload/snapshot/secret fields.
- Keep display names, product/feature/paid-plan selection flags, and price
  records outside entitlement lookup. Only `active AND free` participates as
  the explicit fallback selector.

Migrations: add the focused `platform_audit_events` append-only ledger with actor
FK, bounded action/subject/change-set fields, lookup indexes, checks, and a
database trigger rejecting update/delete. Existing catalog constraints remain
unchanged.

Tests:

- missing/disabled flag and limit deny in the catalog query;
- finite zero and explicit unlimited return distinct typed results;
- lookup by display name is unavailable;
- controlled changes are audited and cannot alter stable identity fields;
- promotion rejects missing/unverified/disabled accounts and public mass
  assignment cannot create an admin;
- ordinary users and organization owners receive neither admin list nor detail;
- critical catalog create/update/deactivate flows and inconsistent-feature
  errors are covered by request/system tests, including rejection of new
  relations under inactive plan/product/feature parents and preservation of
  referenced price/catalog history;
- subscription diagnostic SQL remains tenant-rooted after exact organization
  `public_id` input, no global organization dropdown is loaded, both indexes are
  bounded to 100 rows per page, all diagnostic endpoints are read-only, and
  response bodies exclude secrets, raw payloads, and snapshots.

Acceptance: Catalog returns one deterministic local answer and every internal
mutation is platform-authorized, identity-preserving, transactional, and
audited. No admin diagnostic can mutate billing or expose another organization's
subscription without explicit tenant selection.

### PR-09: Add product roles and permissions — implemented checkpoint

Depends on: PR-07.

**Goal:** create the product-specific positive permission catalog.

Scope:

- Add `ProductRole`, `ProductPermission`, and `ProductRolePermission`.
- Support global system roles and nullable organization-scoped roles while
  keeping a customer-facing custom-role builder out of the MVP.
- Add an idempotent development/test seed for reviewed Analytics/CRM
  roles/permissions; it creates no tenant assignments.
- Use positive permissions only. Inactive roles reject new assignments and are
  ignored by the live runtime permission union; permissions have stable
  definitions and no independent lifecycle flag.

Migrations: product and optional organization FKs, snake-case role and
dot-separated permission key checks, system/scope consistency, partial scoped
role uniqueness, composite supporting keys, role-permission composite FKs, and
duplicate checks.

Tests: reject cross-product/duplicate joins, enforce system/scope consistency,
verify the exact idempotent local mapping, and prove the same key in different
products cannot cross-grant.

Acceptance: product permission catalog is deterministic and independent of
organization roles.

### PR-10A: Add tenant product-membership persistence — implemented checkpoint

Depends on: PR-06 and PR-09.

**Goal:** make tenant product assignments structurally safe before exposing an
authorized management surface.

Scope:

- Add `ProductMembership` and `ProductMembershipRole`.
- Add tenant-scoped transactional add/remove/assign-role/suspend/reactivate
  services as the structural command boundary; PR-10B adds the customer actor
  authorization path without changing their tenant-scoping contract.
- Allow existing assignments to remain dormant without a current plan
  entitlement rather than deleting them on downgrade. The management UI
  does not expose or mutate them until the product is entitled again.
- Product suspension preserves role joins, while removal deletes the assignment.
- A role-less product membership grants no action.
- Extend the PR-04 membership-suspension transaction to delete that
  membership's product memberships/role joins. The existing audited
  `organization.membership.suspended` event is the evidence for the atomic
  cleanup; reactivation never resurrects product access.

Migrations: explicit organization FKs, an active parent-membership integrity
copy/composite FK, membership/product FKs, composite cross-tenant/product FKs,
unique assignment indexes, and a database trigger that accepts global system
roles but rejects a custom role from another organization.

Tests:

- cross-tenant member ID and cross-product/custom-role assignment rejected by
  service and DB;
- duplicate assignments fail;
- suspended organization membership cannot retain assignments;
- product suspension preserves roles and requires explicit reactivation;
- organization-membership suspension followed by re-invite/reactivation
  requires explicit product reassignment;

Acceptance: RBAC assignment data is safe but does not yet imply runtime product
access.

### PR-10B: Authorize and expose product-assignment management — implemented checkpoint

Depends on: PR-10A.

**Goal:** allow owner/admin to manage product assignments through a complete
server-authorized tenant UI.

Scope:

- The `ProductMembershipPolicy` owner/admin + product-entitlement decision and
  tenant-rooted scope are implemented. The tenant controller reloads every
  assignment target through `Current.organization` and every assignable role
  through the selected product's active system-role allowlist.
- Owner/admin may manage assignments; billing/member may not. No organization
  role bypasses product runtime permission checks.
- The customer UI supports add/remove, suspend/reactivate, and role
  assign/unassign flows with explicit empty/suspended states. Dormant
  assignments remain inaccessible while the product is not entitled.
- Each customer mutation passes the actor to a transactional command that
  revalidates live owner/admin authority and product entitlement under the
  organization lock and writes bounded audit evidence.
- Keep organization-specific custom-role creation/editing outside the MVP.

Tests: organization-role policy table, actor/audit command checks, two-tenant
IDOR requests, submitted-role allowlisting, and direct mutation denial for
billing/member actors.

Acceptance: the server-authorized management surface and request coverage are
implemented. Assignment management never grants product-data access; that uses
the full Access gate. Broad keyboard/narrow-viewport evidence remains part of
the shared customer-shell UX hardening checkpoint rather than this security
boundary.

#### Implemented Billing foundation checkpoint

The repository added constrained `Billing::Customer`, `CheckoutAttempt`,
`Subscription`, `WebhookEvent`, and `PlanChange` records plus the basic
`Billing::LemonSqueezy::Client` before PR-11. It now also has a read-only
Entitlements policy/resolver, but no provider mapping, provider locator,
controller, webhook verifier/processor, projection writer, or external side
effect. `raw_payload` is restricted to a bounded screened
diagnostic snapshot and never means a raw request or complete provider payload.
Subscription history is one-way and deletion-protected. The event ledger keeps
a mandatory content fingerprint plus a unique optional provider event identity;
Lemon's lack of a documented delivery ID leaves the fingerprint authoritative
for delivery idempotency.

The remaining PRs extend these tables through backward-compatible migrations
rather than recreating them. Checkout/API responses remain unable to edit local
subscription state; only PR-14B's later verified-webhook-rooted service may do
so. WebMock blocks non-local network access throughout tests.

### PR-11: Add environment-qualified price mapping and checkout persistence

Depends on: PR-05, PR-07–08; initial Lemon test mappings available.

**Goal:** establish constrained provider mapping and checkout correlation state
without an external endpoint.

Scope:

- Add a Billing-owned environment-qualified provider mapping from an exact
  `PlanPrice` to Lemon and extend the existing `Billing::CheckoutAttempt` with
  that exact mapping boundary.
- Add test/live mapping loader with no credentials or real customer data.
- Permit new mapping/checkout selection only when both plan and price are
  active; deactivation blocks selection while preserving historical resolution.
- Generate checkout correlation plaintext only in memory and persist a SHA-256
  digest; no API checkout is created yet.
- Add locked/lazy and sweeper transition for pending attempts at
  `expires_at + 10 minutes`, including static partial-unique behavior.

Migrations: environment-qualified provider-mapping and checkout-attempt tables;
exact PlanPrice/provider mapping/composite supporting keys,
tenant/initiator/provider-mapping FKs, token-digest/provider-ID
unique indexes, pending partial unique, state/environment/timestamp constraints,
and explicit delete restrictions.

Tests:

- mapping uniqueness and exact `PlanPrice`/stable plan identity;
- inactive plans reject new mapping/checkout selection even if a price flag is
  stale-active, while historical mapping remains queryable;
- concurrent pending attempts yield one winner;
- plaintext token never persists/logs and digest uniqueness holds;
- lazy and swept expiry release the unique slot only after delivery grace;
- checkout-attempt state/timestamp/origin tuple constraints.

Acceptance: constrained synthetic mappings/attempts exist, but no public path or
subscription grant exists.

### PR-12: Complete subscription, provider locator, and verified-event ledger

Depends on: PR-11.

**Goal:** complete local authorization projection and global discovery/receipt
infrastructure before accepting provider traffic.

Scope:

- Extend the existing `Billing::Subscription` and inert
  `Billing::WebhookEvent` into projection-ready constrained records, and add the
  global non-authoritative `Billing::ProviderLocator`.
- Bind subscriptions to their original attempt/provider mapping while allowing
  verified current mapping changes; derive the exact plan only through the
  current environment-qualified mapping and `PlanPrice`.
- Add atomic checkout-attempt + checkout-locator creation service and provider
  subscription locator transitions. Checkout locators distinguish unresolved,
  webhook-consumed, and definitive-creation-failure correlation; expiry alone
  stays unresolved.
- Add services for pending-attempt serialization and event claiming/state
  transition, with no external endpoint.
- Define filtered provider envelope DTO and log filtering.
- Extend the existing pure local subscription policy with future verified
  synchronization/mapping preconditions without duplicating its status matrix.

Migrations: subscription, provider-locator, and webhook-event tables; exact
current provider-mapping composite FK, retained origin attempt/mapping composite FK, one
current subscription partial unique, provider/token-digest locator composites,
event fingerprint unique, all status/sync/environment/timestamp/JSON shape
checks, and sweeper indexes.

Tests:

- one current subscription per organization;
- one attempt cannot be associated with two subscriptions;
- locator and fingerprint uniqueness/shape/transition constraints;
- event storage rejects raw/unallowlisted fixture fields at the service boundary;
- malformed/test-live/unknown mapping fails closed without violating exact
  current mapping FK;
- table-driven matrix with trial status plus exact cancelled/configurable
  past-due boundaries and free fallback;
- an existing synchronized subscription retains its referenced inactive plan
  while new checkout remains blocked;
- provider timestamps beyond the five-minute future-skew allowance fail closed;
- access predicate performs zero network calls.

Acceptance: synthetic local records produce deterministic paid/free/no-plan
answers; no public path can create/mutate a subscription.

### PR-13: Add signed webhook ingress and durable receipt

Depends on: PR-12.

**Goal:** accept only authentic, bounded Lemon Squeezy subscription notifications
and acknowledge after durable receipt.

Scope:

- Add global `POST /webhooks/lemon_squeezy` with only action-specific CSRF
  exemption.
- Implement exact raw-body HMAC verifier with constant-time comparison and
  bounded current/previous key rotation.
- Enforce webhook-specific rate/body limits in this PR; validate content type,
  use signed `meta.event_name` as authority, compare the unsigned header only for
  anomaly telemetry, and validate the exact created+updated processing
  allowlist, resource type, store, and environment/test mode.
- Hash allowlisted checkout custom token after HMAC; persist only its digest.
- Fingerprint only provider + configured environment + exact raw body; exclude
  signature and unsigned headers so a mutated header cannot create a new event.
- Implement the exact HTTP outcome table from the billing model: 401/413/415,
  rate-limit 429, durable 200 ignored/quarantined/supported/duplicate, and 503
  transient persistence failure.
- Compute local fingerprint and insert only the filtered event. Keep the route
  environment-gated and production webhook unregistered; enqueue/processing is
  enabled only when PR-14B deploys the complete projection.

Migrations: none unless measured indexes are missing.

Tests: valid signature, byte mutation, malformed/missing key, rotation, 429
rate/body limits, each HTTP outcome, unsupported and envelope/store/environment
mismatch, mutated-header same-body deduplication, custom-token digest/no
plaintext, duplicate, DB failure, and log redaction.

Acceptance: no subscription row can be changed by this PR; production provider
webhook is not enabled yet.

### PR-14A: Add the Lemon subscription client and DTO contract

Depends on: PR-13.

**Goal:** isolate provider HTTP/JSON:API behavior before it can mutate tenant
state.

Scope:

- Extend the existing fixed-origin, timeout-bounded Lemon API client with the
  subscription response DTO mapping needed by projection.
- Enforce a small bounded response-body limit before parsing provider JSON.
- Build only fixed `/v1/subscriptions/:id` requests; never follow payload URLs.
- Validate response type/ID/store/environment/test mode and map an allowlisted
  normalized snapshot without PII/signed URLs.
- Classify timeout/429/404-propagation/5xx as retryable and auth/malformed as
  permanent, with redacted errors.
- Add a job shell that can fetch/validate a claimed verified event but cannot
  write `Billing::Subscription`; production ingress remains disabled.

Migrations: none expected; any normalized snapshot shape field is additive,
constrained, and justified in this PR.

Tests: exact URL/origin/headers, DTO field allowlist, response mismatch, payload
URL SSRF attempt, oversized/truncated response, timeouts, 429, bounded 404, 5xx,
permanent failures, rate-limit handling, and log redaction. Assert zero
subscription mutations.

Acceptance: provider behavior is contract-tested but no subscription mutation or
production webhook enablement exists.

### PR-14B: Add webhook-rooted tenant resolution and projection

Depends on: PR-14A.

**Goal:** make verified webhooks the only subscription mutation path.

Scope:

- Enable after-commit enqueue/sweeper for supported verified receipts and keep
  provider registration restricted to created+updated.
- Resolve candidates only through `Billing::ProviderLocator` by external
  subscription ID or checkout-token digest, then reload every tenant row through
  `Current.organization`.
- Validate exact store/environment/test mode/current+origin price/variant/plan,
  provider-created time, checkout-locator resolution, and subscription
  cardinality.
- Lock and atomically project normalized state, locator, attempt completion,
  event completion, and expired-current supersession.
- Implement `last_seen_provider_updated_at`, stale ignore, equal conflict,
  fail-closed existing-subscription `mapping_error`/`invalid`, and safe recovery.
- A first unknown mapping creates no subscription; a second non-terminal
  subscription quarantines; trusted first-correlation still consumes the
  checkout locator and creates an unresolved subscription locator for safe
  replay. Superseded rows never reactivate.

Migrations: only focused additive constraints/indexes discovered necessary
during projection, each with direct database tests.

Tests:

- locator candidate plus tenant reload and every token/store/price/environment
  mismatch;
- delayed expired-attempt success, post-expiry provider creation denial, and
  competing old/new attempts;
- duplicate, stale, equal-conflicting, reordered, and concurrent events;
- expired-current atomic supersession and later superseded event isolation;
- unknown/malformed first vs existing subscription fail-closed behavior;
- verified same-snapshot replay recovers only after a mapping/code repair and
  cannot bypass timestamp or fingerprint conflict checks;
- every matrix transition including recovery/plan change;
- all tenant mutations occur through `Current.organization`;
- enqueue failure+sweeper recovery.

Acceptance: enable test-mode provider webhook only after automated suite is
green; complete dashboard resend/simulation contract test with sanitized output.

### PR-15: Add central product authorization and a thin vertical slice — implemented checkpoint

Depends on: PR-08, PR-10B, PR-12, PR-14B, and chosen initial product contract.
The implemented application checkpoint uses synthetic/local catalog and
subscription projection state; it does not waive the still-unimplemented
verified Billing projection or approved production catalog inputs.

**Goal:** enforce the complete entitlement AND permission decision on a real
server-side action.

Scope:

- `Access::Decision`, the ordered `Access::Gate`, and the live tenant-rooted
  `Access::PermissionChecker` are implemented with structured reason codes.
- The gate composes the existing `Entitlements::Result`; it does not duplicate
  paid-status, free-fallback, catalog typing, or cache logic inside Access.
- `Products::Analytics::ActionRegistry` maps the five reviewed actions to exact
  Analytics permissions/features. `report_create` additionally requires the
  `report_limit` entitlement and derives a delta of one; clients cannot
  supply/omit those semantics.
- Keep the common gate read-only: compose active tenant membership, the effective
  local plan (accessible paid subscription or active free fallback),
  product/feature entitlement/typed limit, product membership, and permission
  only.
- `AnalyticsReport` is owned by `organization_id`, addressed externally by
  `public_id`, loaded through `Current.organization.analytics_reports`, and
  protected by the product-owned report policy/scope.
- Analytics dashboard and report index/create/show/CSV export routes demonstrate
  boolean-feature, product permission, tenant ownership, and numeric capacity
  composition. CSV output uses fixed columns and neutralizes spreadsheet formula
  prefixes.
- `Products::Analytics::CreateReport` revalidates the common grant while holding
  the organization lock and atomically compares the authoritative tenant report
  count plus its server-owned delta with finite/unlimited capacity; no generic
  metering ledger is added.
- `ApplicationPolicy` and `Scope` expose the same gate for UI predicates and
  request authorization; the concrete Analytics policy and controllers use it.

Migration: `20260716060000_create_analytics_reports.rb` adds only the
tenant-owned report table, with organization foreign key, database-generated
unique public UUID, normalized/length checks, and the tenant list index. The
rows themselves are the authoritative usage set, so there is no counter or
generic capacity table.

Tests:

- full one-factor-at-a-time denial truth table;
- owner/admin no bypass, permission union, same key wrong product;
- boolean missing/false/true;
- numeric zero/exact/over boundary and downgrade behavior;
- concurrent final-unit consumption commits once;
- client attempts to omit/change permission, feature, consuming flag, or delta
  cannot bypass the server action contract;
- two-tenant guessed IDs and direct POST;
- zero Lemon Squeezy calls during every decision.

Acceptance checkpoint: the common gate, action registry, tenant record policy,
atomic report command, CSV exporter, and customer routes are implemented.
Focused request/service/policy evidence proves distinct entitlement and
permission denials, create/show/export behavior, exhausted capacity, and
two-tenant not-found behavior. Chromium system evidence covers the allowed
vertical slice, required-plan locked card, distinct missing-permission state,
direct-route denial, and guessed cross-tenant report ID.

Verification evidence recorded on 2026-07-16; both commands ran in Docker and
the system command used Chromium with CI flags:

```text
bin/rails test test/requests/analytics_customer_product_test.rb test/requests/customer_shell_test.rb test/requests/product_memberships_test.rb test/services/products/analytics test/policies/product_membership_policy_test.rb
42 runs, 410 assertions, 0 failures, 0 errors, 0 skips

bin/rails test test/system/product_access_test.rb
4 runs, 23 assertions, 0 failures, 0 errors, 0 skips
```

### PR-16: Add server-authorized checkout and pending return

Depends on: PR-15 and PR-11/12 production catalog inputs (test mode first).

**Goal:** create safe Lemon Squeezy checkout without making it an access path.

Scope:

- Add tenant checkout create and return/status endpoints.
- Authorize owner/billing only; enforce CSRF, tenant scope, and checkout-specific
  rate limit in this PR.
- Accept local price ID, serialize attempt, send one allowlisted variant,
  canonical return, short expiry, and transient opaque token; create attempt and
  global digest locator atomically and persist/log no plaintext token.
- Validate provider response and handle every outcome that lacks proof of remote
  non-creation (timeout/reset/5xx/truncated/malformed/invalid 2xx) as
  `creation_unknown` without blind duplicate. Only pre-transmission or
  documented definitive no-create rejection may become `failed`.
- Render pending/synchronized states with Turbo refresh.
- Provide accessible live-region/status semantics, focus-safe errors, and a
  responsive no-JavaScript fallback for the pending page.
- Lazily expire pending attempts only after expiry plus delivery grace. Block a
  non-terminal current subscription; permit replacement only after verified
  `expired` and let PR-14B atomically supersede it. Attempt expiry releases the
  one-pending slot but does not resolve its correlation locator.

Migrations: none expected.

Tests: exact role matrix, CSRF/rate limit, client field tampering, provider
response validation, token digest/no plaintext, concurrent/lazy-expired
checkout, timeout/reset/5xx/malformed/invalid-2xx ambiguity versus definitive
no-create failure, terminal/non-terminal replacement, return spoofing, and
explicit proof that redirect/API success leaves subscription/access unchanged;
system coverage for status live-region/focus behavior and no-JavaScript pending
fallback.

Acceptance: test-mode purchase remains pending until the deployed PR-14B
processor consumes a verified webhook, then the local product gate changes on a
later request.

### PR-17: Add subscription management portal and billing UI

Depends on: PR-16.

**Goal:** complete owner/billing subscription UX without a second state mutation
path.

Scope:

- Add tenant billing status page using only local projection.
- Fetch signed portal/payment-management URL just in time after owner/billing
  authorization and portal-specific rate limit; validate origin and redirect
  without storing/logging it.
- Add pending command display for plan change/cancel/resume if exposed directly;
  provider response never updates local subscription.
- Show status, grace/time boundary, sync issue support code, and safe recovery
  messaging without leaking provider internals; keep it responsive and
  keyboard/screen-reader operable.

Migrations: none unless a non-authoritative command-attempt audit table is
explicitly justified; do not overload `Billing::Subscription`.

Tests: roles, tenant isolation, portal URL SSRF/open-redirect validation,
no-persistence/logging, provider failure, command/portal no-grant, and
keyboard/screen-reader-oriented billing status semantics.

Acceptance: cancel/resume/pause/plan-change UI reflects changes only after a
verified `subscription_updated` webhook.

### PR-18A: Complete audit coverage, redaction, and retention

Depends on: PR-06, PR-10B, PR-14B, and PR-15–17.

**Goal:** finish the concrete PostgreSQL audit contract without mixing network/
header work.

Scope:

- Extend the PR-06 append-only `AuditEvent` service to every required
  organization, invitation, assignment, checkout, tenant-resolved webhook
  projection, and subscription transition. Keep pre-tenant ingress evidence in
  bounded security metrics/redacted logs and the global verified-event ledger;
  never guess an audit tenant.
- Enforce create/read-only application behavior, allowlisted metadata, actor/
  organization correlation, and reason-code errors.
- Complete log/parameter/header filtering and automated capture tests.
- After the required legal/privacy approval, add the dedicated 180-day audit
  retention job; it is the only `AuditEvent` application delete path and is
  separately audited.
- Implement the approved 30-day expired/revoked invitation cleanup and 180-day
  normalized webhook/billing-operational cleanup, preserving active billing
  evidence and tenant/provider idempotency keys as required. Configure 30-day
  request-log retention; backup retention remains PR-19 infrastructure scope.

Migrations: focused additive audit indexes/constraints only if PR-06 evidence
shows they are needed; the sink choice is already fixed to PostgreSQL.

Tests: event coverage, actor/system shapes, update prohibition, metadata/log
redaction, tenant scope, per-record retention boundaries/idempotency, active
billing-evidence preservation, and retention audit.

Acceptance: sensitive lifecycle events are durable and no captured log/audit row
contains secrets, raw billing payload, plaintext token, PII, or signed URL.

### PR-18B: Enforce web security policy

Depends on: PR-18A and all public endpoint PRs.

**Goal:** enforce cross-cutting browser/HTTP defenses while preserving the
endpoint-specific rate/body limits that shipped with each endpoint.

Scope:

- Review and regression-test authentication, invitation, checkout, portal, and
  webhook limits; add only missing global abuse controls.
- Stage CSP in report-only, remove required inline dependencies, then enforce.
- Configure frame/content-type/referrer/permissions headers, safe production
  errors, secure cookies, and trusted proxy assumptions for staging.
- Re-run CSRF/open-redirect/SSRF/body-limit tests across HTML, Turbo, and webhook
  entry points.
- Run a final responsive/accessibility pass over authentication, organization
  switching, invitations, product assignments, checkout pending, and billing
  status: semantic labels/errors/status, logical focus, keyboard operation, and
  narrow/wide viewport system flows.

Migrations: none expected.

Tests: CSP/headers, existing endpoint limits, CSRF, safe errors, cookies,
redirect/SSRF, direct high-risk denial, keyboard flows, focus/error semantics,
and representative responsive viewports.

Acceptance: staging browser/header evidence matches the security model.

### PR-18C: Add billing/queue observability and drift operations

Depends on: PR-14B and PR-18A.

**Goal:** make asynchronous local entitlement synchronization operable.

Scope:

- Add metrics/alerts for webhook age, duplicates, retries, quarantine, sync-state
  changes, mapping conflicts, checkout expiry, queue depth/heartbeat, and worker
  recovery.
- Add read-only provider reconciliation at least every six hours. It alerts but
  never writes subscription state.
- Encode launch SLO: drift acknowledgement within 30 minutes and provider resend
  or verified-event replay within four hours.
- Add runbooks and a drill for a completely missed terminal webhook, enqueue
  failure, worker outage, secret rotation, and verified replay.

Migrations: operational state only if required, with bounded fields and
retention; prefer metrics over duplicating billing truth.

Tests/drills: reconciliation no-write assertion, queue/sweeper recovery, alert
thresholds, missed-event response, and redacted runbook output.

Acceptance: staging evidence shows no secret/PII billing payloads in logs and
every production-critical billing failure has an actionable signal.

### PR-19: Harden database and migration operations

Depends on: all schema PRs.

**Goal:** make schema lifecycle and recovery production-safe.

Scope:

- Review all FKs, unique/partial/composite indexes, checks, and delete behavior
  against `data_model.md` using PostgreSQL introspection.
- Decide and document primary/cache/queue/cable database topology and initialize
  all schemas in staging.
- Add deployment migration/preparation step with backward-compatible policy.
- Configure least-privilege runtime/migration credentials and TLS database
  connections.
- Configure automated encrypted backups and perform isolated restore drill.

Migrations: only focused corrective migrations; no large cleanup bundle without
per-constraint tests and rollout notes.

Tests/checks: clean `db:prepare`, migrate from previous release, rollback where
safe, schema load, constraint suite, backup restore, and web/worker compatibility
during rolling deploy.

Acceptance: recorded staging restore and migration rollback/forward evidence.

### PR-20: Make Docker/Kamal production-ready

Depends on: PR-18A–18C, PR-19, and production infrastructure inputs.

**Goal:** replace deployment placeholders with a secret-safe, operable topology.

Scope:

- Configure real environment-specific hosts/registry through non-secret reviewed
  configuration; never commit real credentials.
- Run separate `web` and `job` roles; remove dependence on queue-in-Puma for
  production.
- Supply database URLs/passwords, Rails master key, Lemon keys/secrets, host, and
  mail settings through Kamal/environment secrets.
- Enable proxy TLS, `assume_ssl`, `force_ssl`, HSTS, allowed hosts, secure cookies,
  canonical URLs, readiness, and health checks.
- Remove or document local storage volume; no customer uploads rely on it.
- Add image build/scan, non-root boot, predeploy migration, web/worker smoke,
  rollback, logs, and console access runbooks.

Migrations: none expected.

Checks:

- production image builds without secret layers;
- configuration renders with placeholders in CI and real values only in secured
  deployment environment;
- staging web/worker/database/queue/readiness work;
- rolling deploy and rollback drills pass.

Acceptance: staging topology matches production shape and survives worker/web
restart independently.

### PR-21: Production acceptance and launch gate

Depends on: PR-20.

**Goal:** demonstrate, not assume, the complete MVP contract.

Scope:

- Run automated full suite and all quality/security/image checks.
- Run two-tenant adversarial test, role matrix, full product gate, and numeric
  concurrency scenario.
- Run Lemon Squeezy live-shaped test-mode checkout, redirect-before-webhook,
  duplicate/resend, reorder, cancel/resume/pause/expire, unknown mapping, and
  secret rotation drills.
- Confirm runtime authorization makes no provider calls during provider outage.
- Run worker outage/recovery, queue alert, database backup restore, deploy
  rollback, credential revoke/rotate, and incident runbook exercises.
- Record product/legal/operations sign-off and known residual risks.

Migrations/application behavior: none; fix failures in focused prerequisite PRs,
not inside a broad launch bundle.

Acceptance: every criterion in section 10 has linked automated output or dated
manual evidence and an owner.

## 8. Test strategy by layer

| Layer | Required coverage |
| --- | --- |
| Database | Every FK, unique/partial index, enum/type/range check, composite tenant/product mismatch, delete behavior |
| Model/service | Normalization, stable catalog identity, active/free selection, typed capacity, last owner, idempotency |
| Policy/access | Exact organization role matrix and one-factor-at-a-time product denial truth table |
| Request | Authentication, CSRF, tenant bootstrap, two-tenant IDOR, Turbo/direct POST parity, checkout/webhook codes |
| Job | Current setup/reset, retries, duplicate/reordered event projection, sweeper recovery, quarantine |
| Provider contract | Sanitized official-style payloads, exact HMAC, DTO mapping, fixed-origin HTTP, test/live separation |
| Concurrency | Last owner, pending checkout uniqueness, subscription projection locks, final numeric unit |
| System | Organization switch, invitation, customer shell, product assignment, Analytics entitlement/permission/isolation, checkout pending-to-active, billing status |
| Security/quality | RuboCop, Brakeman, dependency/import audits, redaction, CSP/headers/rate/body limits |
| Operations | DB prepare/migrate/restore, eager load, image build/boot, worker recovery, deploy/rollback |

Tests use at least two organizations and two products wherever an ownership or
product boundary is relevant. A positive fixture is insufficient without the
corresponding cross-boundary negative request.

## 9. Standard verification commands

Once PR-01/02 establish them, the default local/CI command set is:

```bash
bundle check
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

Use the actual final image name after PR-00 naming resolution. A PR may add a
focused command, such as a concurrency or provider contract test, but may not
silently omit a failing standard check. If a check cannot run, report the exact
blocker; do not report it as passing.

Focused results recorded in a detailed checkpoint are evidence only for the
commands shown and do not substitute for the full `bin/ci` baseline. Record
full-gate results separately whenever they are actually run.

## 10. Production MVP acceptance matrix

| ID | Acceptance criterion | Primary evidence/PR |
| --- | --- | --- |
| A1 | Fresh setup prepares PostgreSQL and runs Minitest/quality checks | PR-01–02 CI |
| A2 | User registers without an organization, verifies/authenticates, resets password, and session revokes safely | PR-03 tests/system flow |
| A3 | User belongs to/switches multiple organizations through path tenancy | PR-04–06 request/system tests |
| A4 | Non-member slug and guessed cross-tenant IDs expose/mutate nothing | PR-05 plus every tenant PR |
| A5 | Role matrix and concurrent last-owner invariant are exact | PR-04/06 policy+concurrency tests |
| A6 | Catalog keys are stable; plan-product, flag/finite/unlimited entitlements, free-plan uniqueness, and prices are database-constrained | PR-07–08 DB/service tests |
| A7 | Cross-product roles/permissions/assignments are impossible | PR-09/10A DB plus PR-10B request tests |
| A8 | Owner/admin have no product bypass; all entitlement+RBAC factors are required | PR-15 gate and Analytics request/system truth table |
| A9 | Flag, finite/unlimited limits, and concurrent final-unit consumption are correct | PR-15 Analytics service/concurrency tests |
| A10 | Every paid billing status/time boundary and active-free fallback matches the one canonical matrix | PR-12/14B table tests |
| A11 | Redirect/API/portal success never changes access | PR-16–17 request/integration tests |
| A12 | Forged/mutated/replayed/reordered/mismatched webhooks cannot over-grant | PR-13–14B tests/drills |
| A13 | Verified webhook activates/changes/cancels/recovers/expires local plan | PR-14B test-mode contract |
| A14 | Runtime access works with Lemon unavailable and performs zero provider calls | PR-14B/15 outage assertion |
| A15 | Test/live keys, events, mappings, and data cannot cross | PR-11–14B tests + staging drill |
| A16 | Logs/events contain no secrets, raw billing payload, PII, or signed URLs | PR-18A–18C capture tests/review |
| A17 | Web and worker images build/boot non-root with TLS/host/security settings | PR-20 staging evidence |
| A18 | Queue backlog alerts/recovery and webhook replay runbooks work | PR-18C/21 drill |
| A19 | Database migration, backup restore, and deployment rollback are proven | PR-19–21 evidence |
| A20 | No real secrets/customer data are committed and all open launch inputs have owners | PR-00/21 review |
| A21 | Critical Hotwire/Tailwind flows are responsive, keyboard-operable, and expose clear semantic errors/status | PR-03/05/06/10/16/17/18B system evidence |

## 11. Rollout strategy

1. Deploy foundation, account, tenancy, and catalog tables with no provider
   endpoint enabled.
2. Deploy billing schema and webhook receiver/projection behind missing/disabled
   production configuration; validate with local fixtures.
3. Enable Lemon test-mode webhook and checkout in staging only.
4. Complete lifecycle, duplicate/order, rotation, and worker recovery drills.
5. Load reviewed live billing mappings without customer data; configure live
   webhook after the capable release is healthy.
6. Enable checkout for internal pilot organization(s).
7. Observe queue/billing/authorization signals through at least one lifecycle
   cycle or agreed pilot window.
8. Expand availability only after launch matrix evidence is complete.

Do not seed a subscription or plan grant to simulate payment. Test and pilot
access must arrive through the same verified webhook path as production.

## 12. Rollback and forward-fix principles

- Schema changes are backward-compatible with the previously deployed web and
  worker image during rollout.
- Do not roll back a migration that would discard billing/tenant history; deploy
  a forward fix and disable the affected entry point.
- Webhook ingestion may remain enabled during processor incidents only when
  durable receipt is healthy; otherwise return 503 so provider retries and alert.
- Disabling checkout/portal UI cannot be used as authorization mitigation;
  server policy remains enforced.
- On ambiguous billing state, fail closed for paid-plan selection, preserve
  verified ledger evidence, leave only the explicit active free fallback, stop
  new checkout if necessary, and repair by provider resend/verified-event
  reprocessing.
- Rollback never rewrites local subscription state from redirect/API response.

## 13. Definition of done for the program

The production MVP is done only when:

- PR-00 through PR-21 outcomes are merged or consciously superseded by an
  updated plan/ADR;
- all acceptance matrix rows have objective evidence;
- all relevant automated and manual checks were actually run and results stored;
- no severity-critical/high security finding remains open;
- no unresolved cross-document model, role, status, or tenancy contradiction
  exists;
- production credentials and customer data remain outside code/repository;
- product, engineering, security, and operations owners accept the residual
  risks and rollback/runbook responsibilities.
