# ADR 0001: Use a Rails Modular Monolith

Status: Accepted
Date: 2026-07-15

## Context

The MVP needs identity, path-based tenancy, a global product/plan catalog,
product RBAC, provider billing synchronization, Hotwire UI, background jobs, and
production operations. These capabilities share authorization-sensitive
transactions and are being built by one product team from a greenfield Rails
application.

Premature services would introduce distributed transactions, duplicated tenant
context, network failure in access decisions, and operational overhead before
module contracts or scaling bottlenecks are known. An unstructured Rails
monolith, however, would make it easy for product code to reach directly into
billing, bypass tenant scope, or duplicate entitlement policy.

## Decision

Build one Rails 8.1 application and one release artifact as a modular monolith.
Use one primary PostgreSQL transactional boundary for business data and the
Rails-provided Solid databases for queue/cache/cable according to deployment
configuration.

Define these logical modules:

- Accounts
- Tenancy
- Catalog
- Billing
- Access Control
- Product modules
- Platform/delivery

Keep conventional top-level Active Record aggregate names where Rails clarity
benefits, and namespace orchestration/provider code by owning module. Enforce
dependency direction with documented public services, boundary tests, and code
review. Do not introduce Rails engines, internal gems, Packwerk, or a generic
event bus in the MVP.

The dependency direction is:

```text
Accounts -> Tenancy
Tenancy + Catalog -> Billing
Tenancy + Catalog + Billing -> Access Control
Tenancy + Access Control -> Product modules
all required modules -> Web/job delivery
```

Arrows mean “is used by.” Product modules call the Access Control API and do not
query billing tables. Billing references exact catalog plan versions but does
not own product permissions. Cross-module writes go through the owning service.

Use synchronous Ruby calls and database transactions for in-process domain
work. Use Solid Queue only for work that is naturally asynchronous, retryable,
or outside the request latency budget, such as webhook projection and mail.

## Consequences

### Positive

- Tenant, subscription, entitlement, permission, and product mutations can use
  atomic PostgreSQL transactions.
- Local method calls keep authorization available during provider/network
  outages.
- One repository and release simplify small-PR delivery and refactoring while
  boundaries are still evolving.
- Separate web and worker processes provide operational isolation without
  distributed domain ownership.
- Module extraction remains possible after a stable contract and measured need
  emerge.

### Negative

- Boundary discipline is social/test-enforced initially rather than isolated by
  process or database credentials.
- The application and test suite can grow unless each module owns clear public
  entry points and focused tests.
- A single bad deploy can affect all modules; CI, backward-compatible migrations,
  health checks, and rollback discipline are mandatory.
- Cross-module transactions can become convenient coupling and require review.

## Guardrails

- Each module documents owned models and callable services.
- No product module reaches into `Billing::*` models.
- No provider DTO escapes the Billing boundary.
- No tenant-owned child query bypasses `Current.organization`; documented global
  locators select only a candidate root and never authorize.
- Authorization-sensitive logic is centralized rather than copied across
  controllers/views.
- Maintain the lightweight allowed-dependency architecture test from the
  foundation PR; add heavier dependency tooling only after violation patterns
  justify it.

## Alternatives considered

### Microservices now

Rejected for the MVP because it adds distributed authorization state,
deployment/observability burden, and consistency failure modes without a proven
scaling or team-ownership need.

### Unstructured Rails monolith

Rejected because billing, tenancy, catalog, and product responsibilities need
explicit dependency and data ownership boundaries for security.

### Rails engines/internal gems per module

Deferred. They add packaging/autoload/testing overhead and make early cross-cut
refactoring harder. Reconsider if module APIs stabilize and accidental coupling
persists.

## Revisit triggers

Reconsider extraction or stronger tooling when at least one is true:

- a module needs independent scaling/deployment for measured reasons;
- teams require independent ownership/release cadence;
- database workload isolation is necessary;
- boundary violations recur despite tests/review;
- a stable async contract and local projection strategy already exist.
