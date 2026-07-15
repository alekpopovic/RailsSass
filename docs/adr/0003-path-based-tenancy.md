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

- Organization slugs are globally unique, normalized lowercase ASCII, and
  immutable in the MVP.
- Authenticate first, then use the current user's global, non-authoritative
  `OrganizationAccessLocator` to select a candidate organization
  for the slug.
- Set `Current.organization`, then reload the active membership through that
  organization's association before setting `Current.organization_membership`.
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

1. organization creation inserts a new root, first owner membership, and locator
   in one transaction, then redirects to the ordinary path;
2. ordinary tenant entry/switching uses the account locator only to select a
   candidate, then reloads membership through `Current.organization`;
3. invitation acceptance sets a tentative organization root from the public
   slug and may query only that organization's invitation until digest/email
   validation creates the membership/locator;
4. a tenant job loads the root by its trusted argument, sets `Current`, then
   queries tenant children;
5. verified webhook processing may query only the global
   `Billing::ProviderLocator` by provider subscription ID or checkout-token
   digest, then reload all tenant state through `Current.organization`;
6. global account disablement enumerates only account locators, locks candidate
   roots in stable order, and reloads each tenant's ownership state through
   `Current.organization` before committing.

Global locators are discovery indexes, not grants. Stale/mismatched locators
fail at the authoritative tenant-owned reload. No tenant-owned child table is
queried globally.

Ordinary tenant jobs carry `organization_id`, establish tenant context
explicitly, and never assume request-local `Current` survives enqueueing. A
pre-tenant webhook job carries only its verified event ID and uses the locator
boundary in item 5.

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
- Global locator creation/removal occurs atomically with the authoritative
  membership/provider transition and is always revalidated tenant-side.
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
