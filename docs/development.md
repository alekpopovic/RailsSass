# Development and CI

This guide is the executable setup contract for a clean checkout. It supports
Rails on the host with PostgreSQL and MailCatcher in Docker Compose, or the full
development stack in containers. All checked-in database credentials are
synthetic and development-only; captured email never leaves the workstation.

## Prerequisites

- Docker with Docker Compose v2
- Ruby 4.0.5, Bundler 4.0.14, and PostgreSQL 17 client tools (`pg_dump`) for the
  host-Rails workflow
- Chrome or Chromium for host system tests

Node.js is not required. Importmap and Tailwind are provided by gems.

## Host Rails with Compose PostgreSQL

This is the shortest feedback loop and the recommended default:

```bash
docker compose up --detach --wait postgres mailcatcher
bin/setup --skip-server
bin/dev
```

`docker compose --wait` does not return until PostgreSQL and MailCatcher pass
their healthchecks.
`bin/setup` installs the locked bundle when necessary, copies `.env.example` to
the ignored `.env` only when it is absent, prepares the development database,
and clears stale temporary files. Open <http://localhost:3000> after `bin/dev`
starts Puma and the Tailwind watcher. Rails delivers every development email to
MailCatcher at `127.0.0.1:1025`; open <http://localhost:1080> to inspect HTML,
plain-text, and source versions without contacting a real mail provider.

Run the complete local quality gate from another terminal:

```bash
bin/ci
```

The default `.env.example` connects host Rails to the published PostgreSQL port
with synthetic `rails_sass` credentials. If port 5432 is occupied, choose a host
port in the ignored `.env`, then use the same value when starting PostgreSQL:

```bash
PGPORT=55432 docker compose up --detach --wait postgres mailcatcher
PGPORT=55432 bin/setup --skip-server
```

To use a native PostgreSQL installation instead, replace or remove the `PGHOST`,
`PGPORT`, `PGUSER`, and `PGPASSWORD` values in `.env`. Rails continues to honor
standard libpq variables and `DATABASE_URL`; no application-specific database
configuration interface is required.

## Containerized Rails and PostgreSQL

The development image includes the locked Ruby toolchain, build dependencies,
Chromium, and ChromeDriver, so it can run both the application and `bin/ci`:

```bash
docker compose up --detach --wait postgres mailcatcher
docker compose build app
docker compose run --rm app bin/setup --skip-server
docker compose up app
```

Open <http://localhost:3000>. The app container uses the internal hostname
`postgres` for PostgreSQL and `mailcatcher:1025` for SMTP. Compose overrides the
host-oriented settings without changing the tracked example or the ignored
`.env`; the inbox remains available at <http://localhost:1080>.

Run the same quality gate inside the development image with:

```bash
docker compose run --rm app bin/ci
```

The image defaults to UID/GID 1000 so bind-mounted files are not owned by root.
On a host with different IDs, rebuild with explicit values:

```bash
LOCAL_UID=$(id -u) LOCAL_GID=$(id -g) docker compose build app
```

## Entitlement policy

`ENTITLEMENTS_PAST_DUE_GRACE_DAYS` is a non-secret non-negative integer and
defaults to `15` for host and Compose Rails processes. Invalid values fail boot.
The status policy uses this duration from the stable local
`past_due_started_at`; changing it never writes subscription state.

## Lemon Squeezy adapter

Ordinary setup, boot, and tests do not require provider credentials. The tracked
`.env.example` exposes empty `LEMON_SQUEEZY_API_KEY` and
`LEMON_SQUEEZY_STORE_ID` placeholders only; keep real values in the ignored
`.env` for local manual work or in Rails credentials/deployment secret storage.
The client resolves explicit constructor values first, then non-blank environment
variables, then the matching `lemon_squeezy` Rails credential entries. Missing
configuration raises a redacted configuration error before any request.

```yaml
lemon_squeezy:
  api_key: replace-in-your-encrypted-credentials
  store_id: replace-in-your-encrypted-credentials
```

The adapter uses a fixed Lemon HTTPS origin, explicit connect/read timeouts, and
one network attempt per call. It does not implement checkout, webhook delivery,
or subscription projection. The test helper enables WebMock globally and blocks
all non-local network traffic while allowing localhost for Rails/system tests;
provider tests must stub every request with synthetic data.

## Internal platform administration

Public registration cannot assign `system_role`. After an intended administrator
has registered and verified the email, promote that existing enabled account
explicitly:

```bash
bin/rails "platform_admin:promote[admin@example.test]"
```

The task normalizes the email, locks the user, rejects blank/missing, unverified,
or disabled accounts, and idempotently changes only `system_role`. It does not
create an organization or grant an organization/product role. For containerized
Rails, run the same command through the app service:

```bash
docker compose run --rm app bin/rails "platform_admin:promote[admin@example.test]"
```

Authenticate as that user and open <http://localhost:3000/admin>. Catalog writes
are audited and preserve stable identities. Product, feature, plan, and price
records are deactivated instead of deleted; plan-product rows are create-only;
entitlements are disabled with `enabled=false` rather than deleted. A new
plan-product requires an active plan and product, a new plan-price requires an
active plan, and a new entitlement requires its plan, product, and feature to be
active. Deactivation retains existing catalog and billing-history relationships
but blocks new ones. A price with billing history can only be
activated/deactivated; create a new price to change its commercial or Lemon
mapping fields. Advanced entitlement settings are intentionally not rendered by
this interface and the `settings` parameter is filtered from logs.

Subscription diagnostics require one exact organization `public_id`, do not
load a global organization dropdown, and remain scoped through
`Current.organization`; failed webhook events are read from the global ledger.
Both indexes are bounded to 100 rows per page and both views are read-only. They
never display Lemon credentials, webhook secrets, raw payloads,
`pause`/`snapshot` JSON, or signed provider URLs. Real administrator email
addresses are operational PII and must not be added to tracked examples,
fixtures, or documentation.

## Quality gate

`bin/ci` forces `RAILS_ENV=test`, uses a single worker by default, and stops at
the first failed step. Its order is:

1. Verify the locked bundle, update/check the Ruby advisory database, and audit
   Importmap dependencies.
2. Run the Rails Omakase RuboCop configuration.
3. Prepare the PostgreSQL test database and build Tailwind CSS.
4. Run unit/integration tests and system tests when `test/system/**/*_test.rb`
   exists.
5. Check Zeitwerk eager-loading boundaries.
6. Run Brakeman with warnings and errors treated as failures.

Run `bin/setup --skip-server` once before `bin/ci` on a clean host checkout.
The quality gate deliberately does not install dependencies, create `.env`, or
clear diagnostics.

## GitHub Actions

The CI workflow runs `bin/ci` against a disposable PostgreSQL service with
synthetic credentials. `ruby/setup-ruby` caches only the lockfile-resolved gem
bundle. It installs the PostgreSQL 17 client from the official PostgreSQL Apt
repository so `psql`/`pg_dump` match the service major version; database state
and environment files are never cached. On failure, the
workflow retains `log/test.log` and any Capybara/system-test screenshots when
they exist.

After the quality gate succeeds, a dependent job builds the production image,
starts it with a dummy secret-key base and no deployment credentials, and checks
`/up`. This is an image smoke test, not a deployment workflow.

Dependabot checks Bundler, GitHub Actions, and Docker dependencies weekly.

## Database lifecycle and troubleshooting

Development and test may load the synthetic local catalog repeatedly:

```bash
bin/rails db:seed
RAILS_ENV=test bin/rails db:seed
```

Test `db:prepare` uses `seeds: false`, so quality-gate database preparation is
deterministic and does not grant catalog or RBAC state implicitly. Run the
explicit test seed command only when manually exercising seeded test data;
automated tests create the exact catalog and access graph they require.

The task converges products `core`, `analytics`, and `crm` plus plans `starter`
and `professional` by stable key. Analytics also receives the flag features
`dashboards`, `custom_reports`, and `csv_export` plus the numeric
`report_limit`. For both Analytics and CRM the task converges the active system
roles `viewer`, `contributor`, and `product_admin` with this synthetic
permission map:

| Product | Viewer | Contributor | Product Admin |
| --- | --- | --- | --- |
| Analytics | `analytics.dashboard.read`, `analytics.report.read` | Viewer permissions plus `analytics.report.create`, `analytics.export.run` | All five Analytics permissions, including `analytics.report.manage` |
| CRM | `contacts.view` | `contacts.view`, `contacts.manage` | `contacts.view`, `contacts.manage`, `settings.manage` |

Repeated execution repairs mutable display metadata and restores missing
reviewed mappings while preserving stable identities and refusing to change an
existing feature's kind. It is a no-op outside development/test and does not
create Core roles, organization-specific roles, plan-product rows,
entitlements, prices, Lemon identifiers, subscriptions, product memberships, or
tenant access grants.

## Runtime product access

Analytics controllers, policies, commands, and presentation predicates resolve
security semantics from the same action registry:

```ruby
decision = Products::Analytics::ActionRegistry.decision(
  :report_create,
  context: AuthorizationContext.current
)
```

The registry invokes the read-only common gate with fixed product, permission,
feature, and capacity semantics. It uses local database state and never calls
Lemon Squeezy. Controllers still call Pundit's `authorize`/`policy_scope`, and
`Products::Analytics::CreateReport` repeats the decision under an organization
lock before measuring `Current.organization.analytics_reports` and inserting a
row. Product-member administration is separate: `ProductMembershipPolicy`
permits active owner/admin actors only when the effective plan includes the
product, while billing/member actors deny; the command revalidates that actor
authority inside its transaction.

The primary PostgreSQL database uses `db/structure.sql` so a clean schema load
preserves database functions and deferred constraint triggers. Generate it only
through Rails migration/schema tasks; do not edit it by hand. Solid
Cache/Queue/Cable continue to use their Rails-managed Ruby schema files.

Inspect service health and logs with:

```bash
docker compose ps
docker compose logs postgres
docker compose logs mailcatcher
docker compose exec postgres pg_isready -U rails_sass -d rails_sass_development
```

If ports 1025 or 1080 are already occupied, set `SMTP_PORT` or
`MAILCATCHER_HTTP_PORT` in the ignored `.env`, then restart MailCatcher. The web
UI is intentionally bound to `127.0.0.1` because it has no authentication.

Authentication mail is enqueued with `deliver_later` and runs through the
in-process development async queue. Rails reads SMTP and queue configuration at
boot, so recreate an already-running app container after changing `.env`,
`compose.yaml`, or the development mailer configuration:

```bash
docker compose up --detach --wait mailcatcher
docker compose up --detach --force-recreate app
```

Action Mailer body logging is disabled because authentication messages contain
signed tokens. Delivery exceptions still surface through Active Job. If the
inbox remains empty, inspect only the web-process delivery error:

```bash
docker compose logs app | grep -E 'Net::SMTP|ECONNREFUSED|Error performing'
```

Stop containers while preserving the database volume:

```bash
docker compose down
```

Delete all Compose development data only when a destructive reset is intended:

```bash
docker compose down --volumes
```

If gems change, rebuild `app` or run `bin/setup --skip-server` in the container;
the named bundle volume is writable by the development user. If system tests
fail, their screenshots are written under `tmp/screenshots/`.
