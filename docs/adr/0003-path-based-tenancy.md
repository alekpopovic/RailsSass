# ADR 0003: Use Path-Based Organization Tenancy

Status: Accepted
Date: 2026-07-15

## Context

A user can belong to multiple organizations and switch between them. The MVP
needs explicit tenant context for routes, authorization, links, request tests,
background jobs, and billing UI. Custom domains/subdomains add DNS, certificate,
cookie, development, and deployment complexity that is not required for the
initial product.

A path slug is convenient routing context but cannot itself prove membership.
Implicit tenant `default_scope` can hide missing context, create unsafe unscoped
escapes, and behave poorly in global/provider workflows.

## Decision

Use path-based tenancy for ordinary tenant UI and application routes:

```text
/o/:organization_slug/...
```

- Organizations have a database-generated unique public UUID, globally unique
  normalized lowercase-ASCII immutable slug, and `active`/`suspended` status.
  Suspended organizations cannot establish ordinary tenant context.
- Authenticate first, then use the current user's global, non-authoritative
  `OrganizationAccessLocator` to select a candidate organization
  for the slug.
- Set `Current.organization`, then reload the active membership through that
  organization's association before setting `Current.membership`.
- After the candidate root is set, every tenant-owned child query starts from a
  `Current.organization` association and applies a Pundit policy scope/policy.
- Tenant-owned rows include non-null `organization_id`; composite foreign keys
  prevent cross-tenant joins.
- Do not use tenant `default_scope`.
- Clear `Current` in `ensure` after every request and tenant job.
- A non-member slug and a cross-tenant record identifier return not found.
- Global authentication/account, organization creation, health, readiness, and
  Lemon webhook routes are outside the ordinary tenant path.

Context establishment is explicit:

1. verified-and-authenticated onboarding explicitly invokes
   `Organizations::Create`; registration and email verification never invoke it
   automatically. The initial foundation transaction inserts the active root and
   first active owner membership, then sets request-local `Current` only after
   commit;
2. before any ordinary tenant path is enabled, the path-bootstrap migration adds
   and backfills locators for all active memberships. It then extends new
   organization creation to insert the locator atomically and may redirect to the
   ordinary path;
3. ordinary tenant entry/switching uses the account locator only to select a
   candidate, then reloads membership through `Current.organization`;
4. invitation acceptance sets a tentative organization root from the public
   slug and may query only that organization's invitation until digest/email
   validation creates the membership/locator;
5. a tenant job loads the root by its trusted argument, sets `Current`, then
   queries tenant children;
6. verified webhook processing may query only the global
   `Billing::ProviderLocator` by provider subscription ID or checkout-token
   digest, then reload all tenant state through `Current.organization`;
7. global account disablement remains unexposed until its dedicated guard can
   enumerate only account locators, lock candidate roots in stable order, and
   reload each tenant's ownership state through `Current.organization` before
   committing.

Global locators are discovery indexes, not grants. Stale/mismatched locators
fail at the authoritative tenant-owned reload. No tenant-owned child table is
queried globally.

Ordinary tenant jobs carry `organization_id`, establish tenant context
explicitly, and never assume request-local `Current` survives enqueueing. A
pre-tenant webhook job carries only its verified event ID and uses the locator
boundary in item 6.

## Consequences

### Positive

- Tenant context is visible in URLs, route helpers, logs, tests, and support
  reports.
- Users can switch organizations without cookie/domain changes.
- Local development and single-domain TLS/deployment remain simple.
- Tenant-rooted queries and composite constraints provide explicit defense in
  depth.
- The same account/session works across all memberships.

### Negative

- URLs change if slug renaming is later introduced; MVP therefore keeps slugs
  immutable.
- Developers must carry tenant route parameters and establish `Current` in
  every tenant job.
- Global uniqueness means a desired slug can be unavailable even across
  unrelated tenants.
- A path makes organization slugs observable to members and potentially
  guessable, though membership-scoped resolution prevents access.

## Required implementation guardrails

- Tenant loader runs before tenant record loaders.
- No tenant path is enabled until the initial active-membership locator backfill
  is complete. Thereafter global locator creation/removal occurs atomically with
  the authoritative membership activation/soft-suspension or provider transition
  and is always revalidated tenant-side.
- `verify_authorized` and `verify_policy_scoped` cover authenticated tenant
  controllers.
- Shared query/service APIs require or read explicit current organization and
  fail when absent.
- Tests use two or more organizations and attempt guessed IDs on every tenant
  resource family.
- Request and job tests prove `Current` reset after success and exception.
- Route generation in mail/jobs receives an explicit organization slug; it does
  not read stale global context.

## Alternatives considered

### Subdomain tenancy

Deferred because it adds wildcard DNS/TLS, cookie-domain, local-development, and
proxy complexity without improving MVP authorization. It remains possible with
the same data/query model later.

### Custom domains

Out of scope due to ownership verification, certificate lifecycle, abuse, and
routing complexity.

### Tenant selected only by session/cookie

Rejected because links become ambiguous, multiple tabs can conflict, and tenant
context is less visible during review and debugging.

### Database per tenant or PostgreSQL schema per tenant

Rejected for the MVP due to migration, connection-pool, operations, and global
account/catalog complexity. Shared tables with explicit ownership and
constraints meet current scale and isolation needs.

### PostgreSQL row-level security

Deferred as an additional defense layer. It does not replace correct application
bootstrap, Pundit, job context, or billing resolver design.

## Revisit triggers

- customer demand for branded domains/subdomains;
- regulatory/isolation requirements that justify RLS or physical separation;
- slug rename requirement with redirect/history policy;
- operational scale requiring tenant-aware partitioning.
