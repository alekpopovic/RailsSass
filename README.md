# RailsSass Foundation

This repository is the executable foundation for a modular-monolith SaaS built
with Rails 8.1, PostgreSQL, Hotwire, Tailwind CSS, Pundit, Solid Queue, Propshaft,
Faraday, and Minitest.

The current slice contains global email/password authentication but intentionally
has no organization, tenant-owned domain models, or live Lemon Squeezy integration.
Registration never creates an organization. The target behavior and delivery sequence are in
[`docs/`](docs/), beginning with the
[product requirements](docs/product_requirements.md),
[architecture](docs/architecture.md), and
[production MVP execution plan](docs/exec_plans/production_mvp.md).

## Prerequisites

- Docker with Docker Compose v2 for the default development PostgreSQL
- For host Rails: Ruby 4.0.5, Bundler 4.0.14, and Google Chrome or Chromium

The application uses gem-provided Importmap and Tailwind binaries, so Node.js is
not required for this foundation. See the complete host and container workflows
in [Development and CI](docs/development.md).

## Local setup

Install the matching Bundler version if necessary:

```bash
gem install bundler -v 4.0.14
```

Start PostgreSQL and MailCatcher and wait for both healthchecks, then run the
idempotent setup:

```bash
docker compose up --detach --wait postgres mailcatcher
bin/setup --skip-server
```

`bin/setup` installs gems, preserves an existing `.env`, runs `db:prepare`, and
clears stale logs and temporary files. Use `bin/setup --reset --skip-server` only
when intentionally replacing local development data.

The tracked `.env.example` contains only synthetic Compose credentials and is
copied automatically when `.env` is absent. Native PostgreSQL remains supported
by replacing or removing the standard `PG*` values in the ignored `.env`.

### Fully containerized development

Rails can also run in the dedicated development image:

```bash
docker compose build app
docker compose run --rm app bin/setup --skip-server
docker compose up app
```

The image includes Chromium/ChromeDriver, so
`docker compose run --rm app bin/ci` executes the same quality gate as the host.

## Run the application

Start Puma and the Tailwind watcher together:

```bash
bin/dev
```

Open <http://localhost:3000>. The liveness endpoint is
<http://localhost:3000/up>.

New accounts must verify their email address before signing in. Development
sends every message to the local MailCatcher SMTP service; inspect the inbox at
<http://localhost:1080>. Nothing is forwarded to a real provider. Production
must set `APP_HOST`, `MAILER_FROM`, and a real delivery adapter through its
secret/configuration store.

If Rails was already running when MailCatcher or its SMTP settings were added,
restart `bin/dev` or recreate the `app` container so Rails reloads its
boot-time mailer configuration.

The application operates in `Europe/Belgrade`; Active Record persists database
timestamps in UTC.

## Database and jobs

The default databases are `rails_sass_development` and `rails_sass_test`.
Prepare the current environment with:

```bash
bin/rails db:prepare
```

Solid Queue is configured as the production Active Job adapter with its own
database connection. Production must run a separate worker process:

```bash
bin/jobs
```

Do not enable access from a checkout redirect or outbound Lemon API response.
Runtime authorization will use local database state, and only verified,
durably recorded, idempotently processed webhooks may change subscription state.

## Tests and quality checks

Run the foundation suites and autoload check:

```bash
bin/rails test
bin/rails test:system
bin/rails zeitwerk:check
```

Run style and security checks:

```bash
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

`bin/ci` forces the test environment and stops on the first failed dependency,
style, database, test, autoload, or security gate. Run `bin/setup --skip-server`
first on a clean checkout. Set `TEST_WORKERS` to opt into parallel Minitest
workers; the safe default is one worker until CI database isolation is proven.

## Repository structure

- `app/` — Rails controllers, views, policies, jobs, and future namespaced modules
- `config/` — Rails, PostgreSQL, Solid Queue, assets, and deployment configuration
- `db/` — primary schema plus Rails-managed Solid Cache/Queue/Cable schemas
- `test/` — request, policy, configuration, architecture, and system Minitests
- `docs/` — requirements, architecture, security, billing, ADRs, and execution plan
- `public/` — static health-independent error pages and public assets
- `bin/` — setup, development, test/quality, job, and deployment entrypoints
- `compose.yaml` / `Dockerfile.dev` — local PostgreSQL, MailCatcher, and containerized development

## Configuration and secrets

`.env.example` contains synthetic development-only values and placeholders.
`.env`, Rails key files, production credentials, Lemon keys, webhook secrets,
and customer data must never be committed. Production values belong in the
deployment secret store and must be passed through environment variables or
Rails credentials.

Kamal files are still generator-level placeholders. Do not deploy them as-is;
the production topology, hosts, registry, TLS settings, database credentials,
and separate worker role are completed in the production milestone described in
the execution plan.
