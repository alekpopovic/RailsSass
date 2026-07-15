# RailsSass Foundation

This repository is the executable foundation for a modular-monolith SaaS built
with Rails 8.1, PostgreSQL, Hotwire, Tailwind CSS, Pundit, Solid Queue, Propshaft,
Faraday, and Minitest.

The current slice intentionally contains no domain models, tenant behavior, or
live Lemon Squeezy integration. The target behavior and delivery sequence are in
[`docs/`](docs/), beginning with the
[product requirements](docs/product_requirements.md),
[architecture](docs/architecture.md), and
[production MVP execution plan](docs/exec_plans/production_mvp.md).

## Prerequisites

- Ruby 4.0.5, as declared by `.ruby-version`
- Bundler 4.0.14, as declared by `Gemfile.lock`
- PostgreSQL with permission to create local development and test databases
- Google Chrome or Chromium for system tests
- Docker only if you prefer a containerized local PostgreSQL server

The application uses gem-provided Importmap and Tailwind binaries, so Node.js is
not required for this foundation.

## Local setup

Install the matching Bundler version if necessary:

```bash
gem install bundler -v 4.0.14
```

PostgreSQL defaults to the current operating-system user over a local socket.
Ensure that role exists and can create databases. For example, on a Linux host
with PostgreSQL packages installed:

```bash
sudo -u postgres createuser --createdb "$USER"
```

If the role already exists, PostgreSQL will report that and no change is needed.

Create the ignored local environment file, edit it only if your PostgreSQL
connection differs from the socket default, and run the idempotent setup:

```bash
cp .env.example .env
bin/setup --skip-server
```

`bin/setup` installs gems, preserves an existing `.env`, runs `db:prepare`, and
clears stale logs and temporary files. Use `bin/setup --reset --skip-server` only
when intentionally replacing local development data.

### PostgreSQL with Docker

As an alternative to a host PostgreSQL installation, start a disposable local
server with synthetic development-only credentials:

```bash
docker run --name rails-sass-postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -d postgres:17-alpine
```

Then set these values in the ignored `.env` before running `bin/setup`:

```dotenv
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
```

## Run the application

Start Puma and the Tailwind watcher together:

```bash
bin/dev
```

Open <http://localhost:3000>. The liveness endpoint is
<http://localhost:3000/up>.

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

`bin/ci` runs setup, the test suites, autoloading, style, and security checks in
one local command. Set `TEST_WORKERS` to opt into parallel Minitest workers; the
safe default is one worker until CI database isolation is proven.

## Repository structure

- `app/` — Rails controllers, views, policies, jobs, and future namespaced modules
- `config/` — Rails, PostgreSQL, Solid Queue, assets, and deployment configuration
- `db/` — primary schema plus Rails-managed Solid Cache/Queue/Cable schemas
- `test/` — request, policy, configuration, architecture, and system Minitests
- `docs/` — requirements, architecture, security, billing, ADRs, and execution plan
- `public/` — static health-independent error pages and public assets
- `bin/` — setup, development, test/quality, job, and deployment entrypoints

## Configuration and secrets

`.env.example` contains only commented examples and placeholders. `.env`, Rails key
files, production credentials, Lemon keys, webhook secrets, and customer data
must never be committed. Production values belong in the deployment secret
store and must be passed through environment variables or Rails credentials.

Kamal files are still generator-level placeholders. Do not deploy them as-is;
the production topology, hosts, registry, TLS settings, database credentials,
and separate worker role are completed in the production milestone described in
the execution plan.
