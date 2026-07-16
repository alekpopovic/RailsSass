# Repository Instructions

These instructions apply to the entire repository. Source code, class names,
database identifiers, tests, commit messages, and technical documentation are
written in English.

## Required workflow

Before changing code:

1. Read this file and the relevant documents in `docs/`.
2. Inspect the existing implementation, migrations/schema, tests, and
   `git status`; do not assume a previous task was implemented perfectly.
3. State a short plan before editing.
4. Implement the smallest coherent change that completes the task.
5. Preserve public interfaces unless the requested behavior requires a change.
6. Add or update tests for every behavior change.
7. Run all relevant tests and quality checks, and report only commands actually
   executed.
8. Do not commit unless the user explicitly requests a commit.

Preserve unrelated work in a dirty worktree. Never use destructive Git commands
to discard changes that are not yours.

## Repository structure

- `app/controllers/` — HTTP orchestration; controllers stay thin.
- `app/models/` — persistence and record-local invariants.
- `app/policies/` — Pundit policies and scopes.
- `app/services/` — namespaced application commands and queries.
- `app/jobs/` — asynchronous entrypoints that re-establish required context.
- `app/views/` and `app/javascript/` — Hotwire/Tailwind UI and Stimulus behavior.
- `config/` — Rails/application/infrastructure configuration.
- `db/` — migrations, primary PostgreSQL `structure.sql`, and Solid
  Cache/Queue/Cable schemas.
- `test/` — Minitest suites mirroring application boundaries.
- `docs/` — normative product, architecture, security, billing, ADR, and plan
  documents. Update them when an implementation changes a documented contract.
- `compose.yaml` and `Dockerfile.dev` — reproducible local PostgreSQL,
  MailCatcher, and the optional containerized Rails development process.

The application is a modular monolith, not a collection of Rails engines.
Domain code is grouped by clear namespaces and dependency boundaries documented
in `docs/architecture.md`.

## Commands

```bash
# Start development PostgreSQL and MailCatcher and wait until both are healthy
docker compose up --detach --wait postgres mailcatcher

# Install dependencies and prepare PostgreSQL
bin/setup --skip-server

# Run Puma and Tailwind watcher
bin/dev

# Prepare database
bin/rails db:prepare

# Tests
bin/rails test
bin/rails test:system

# Autoloading and style
bin/rails zeitwerk:check
bin/rubocop

# Security and dependency scans
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit

# Combined local CI sequence
bin/ci
```

`bin/ci` always runs with `RAILS_ENV=test` and stops at the first failed gate.
It verifies the locked bundle and dependency advisories, runs RuboCop, prepares
the test database, builds Tailwind, runs Rails and (when present) system tests,
checks autoloading, and finishes with Brakeman. Run `bin/setup --skip-server`
first on a clean checkout; `bin/ci` intentionally does not install gems or
modify local environment files. The equivalent container command is
`docker compose run --rm app bin/ci`.

Use focused test paths while iterating, then run every relevant full command
before handoff. A command that was not run must be reported as not run, never as
passing.

## Rails naming and service objects

- Follow Rails naming, file-path, inflection, and REST conventions.
- Use singular model names, plural table names, and descriptive route/action
  names. Do not abbreviate durable domain identifiers.
- Namespace domain behavior by module (`Accounts`, `Tenancy`, `Catalog`,
  `Billing`, `Entitlements`, `Access`, and product modules) according to the
  architecture.
- Service objects represent one command or query, use a descriptive operation
  name, accept explicit keyword inputs, and expose one public `#call` method.
- Initializers assign inputs only. Side effects happen in `#call` and are covered
  by tests. Transactions live at the command boundary that owns the invariant.
- Keep provider payloads behind adapter/DTO boundaries. Do not leak Lemon JSON
  structures into models, policies, controllers, or product modules.
- Prefer ordinary Ruby objects and direct calls. Add abstractions only when a
  real boundary or repeated behavior requires them.

## Tenant scoping

- The tenant route shape is `/o/:organization_slug/`.
- Every tenant-owned query must be explicitly rooted through
  `Current.organization`, for example
  `Current.organization.projects.find(params[:id])`.
- Never use an unscoped tenant model lookup followed by an in-memory
  organization check. Avoid tenant `default_scope`; make ownership visible in
  every query.
- A global user-owned locator may identify only a candidate organization. Set
  `Current.organization`, then reload the authoritative active membership and
  tenant records through that organization.
- Submitted organization, membership, product, role, permission, price, and
  record IDs are untrusted and must be re-resolved through owned associations or
  explicit global catalog allowlists.
- Jobs do not inherit request-local `Current` state. Serialize stable IDs,
  re-establish and validate tenant context at job start, and reset it in an
  `ensure` block.
- Cross-tenant absence should not reveal data. Add negative two-tenant tests for
  every tenant-owned controller/service family.

## Authorization

- Pundit is the controller/policy integration layer. Use `authorize` for records
  and `policy_scope` for collections, with verification hooks in authenticated
  controllers and only narrow, documented exclusions.
- UI hiding is presentation only and is never a substitute for server-side
  authorization. Test direct HTTP mutations for denied actors.
- Fail closed when user, organization, membership, entitlement, product
  membership, role, permission, or numeric-limit input is missing or
  inconsistent. A missing, blocked, or inconsistent paid subscription cannot
  select a paid plan; only the explicit active free-plan fallback may supply an
  effective plan, and it never bypasses the remaining authorization factors.
- Organization roles do not imply product permissions. Product access requires
  both a local plan entitlement and the matching product permission, plus active
  organization and product memberships.
- Numeric limits are enforced by the product-owned command using authoritative
  usage and a server-calculated delta in the same transaction as the mutation.
- Authorization-affecting catalog writes must advance `updated_at` so
  version-keyed entitlement caches invalidate; do not use unversioned
  `update_all` or direct SQL for those mutations.

## Billing and webhooks

- The local PostgreSQL projection is the only runtime source of truth for
  subscription and entitlement authorization.
- A checkout/portal redirect or successful outbound Lemon API response never
  unlocks access. Only processing rooted in a verified, durably stored webhook
  may change local subscription state.
- Verify the signature over the exact raw request body before JSON parsing or
  tenant resolution. Validate expected event, environment, store, and payload
  shape before projection.
- Persist a provider event ledger with a unique provider event ID. Receipt and
  processing must be idempotent, retry-safe, monotonic, and auditable.
- A webhook endpoint acknowledges only after durable receipt, then delegates
  bounded processing to Solid Queue. Production runs workers separately from web
  processes.
- Lemon API calls use the Faraday adapter boundary with a fixed HTTPS origin,
  bounded timeouts, strict response mapping, and safe retry rules.
- Never log raw webhook bodies, signatures, API keys, signed portal URLs, or
  unnecessary personal data.

## Database and migrations

- PostgreSQL is authoritative. Application validations supplement, but never
  replace, database integrity.
- Every relationship requires a foreign key. Tenant/product relationships use
  composite foreign keys where needed to make cross-tenant or cross-product rows
  impossible.
- Add required `NOT NULL`, check constraints, and unique indexes with the table
  or behavior they protect. Index foreign keys and actual lookup paths.
- Normalize durable identifiers before persistence and enforce their normalized
  uniqueness in the database.
- Use reversible, backward-compatible expand/contract migrations. Separate
  destructive cleanup from the code release that stops using old data.
- The primary database uses the SQL schema format because PostgreSQL functions
  and deferred constraint triggers are part of its integrity contract. Keep
  auxiliary Solid Cache/Queue/Cable schema formats unchanged unless required.
- Do not edit generated schema files by hand. Run migrations and inspect schema
  changes before handoff.
- Avoid callbacks for cross-aggregate workflow or external side effects; use an
  explicit service and transaction boundary.

## Tests and definition of done

Use Minitest layers appropriate to the change: model/constraint, policy/service
truth table, request/IDOR, job/retry, provider contract, concurrency, and system
tests. Use synthetic fixtures and locally generated test secrets only.

A task is done only when:

- requested behavior and relevant documentation agree;
- tenant scoping and server authorization are explicit where applicable;
- database constraints protect new invariants where applicable;
- behavior changes have positive and negative automated tests;
- relevant test, Zeitwerk, lint, and security commands were actually run;
- setup/migration/rollback or compatibility steps are documented;
- no secret, production credential, or real customer data was introduced; and
- `git status` was reviewed and no commit was made without explicit approval.

The final handoff must include:

- implementation summary;
- key design decisions;
- changed files;
- migrations and commands to run;
- actual test and quality-check results;
- known risks or open questions; and
- a suggested commit message.

## Secrets prohibition

Never commit `.env`, `config/master.key`, decrypted credentials, production
database URLs, Lemon API/webhook secrets, registry passwords, private keys,
access tokens, signed URLs, raw provider payloads, or real user/customer data.
Tracked example files contain placeholders or synthetic local-only defaults.
Production secrets come from the deployment secret store and are injected at
runtime. If a secret is discovered in tracked content, stop, avoid printing it,
and report the remediation requirement.
