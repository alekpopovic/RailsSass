# Development and CI

This guide is the executable setup contract for a clean checkout. It supports
Rails on the host with PostgreSQL in Docker Compose, or both Rails and
PostgreSQL in containers. All checked-in database credentials are synthetic and
development-only.

## Prerequisites

- Docker with Docker Compose v2
- Ruby 4.0.5 and Bundler 4.0.14 for the host-Rails workflow
- Chrome or Chromium for host system tests

Node.js is not required. Importmap and Tailwind are provided by gems.

## Host Rails with Compose PostgreSQL

This is the shortest feedback loop and the recommended default:

```bash
docker compose up --detach --wait postgres
bin/setup --skip-server
bin/dev
```

`docker compose --wait` does not return until PostgreSQL passes its healthcheck.
`bin/setup` installs the locked bundle when necessary, copies `.env.example` to
the ignored `.env` only when it is absent, prepares the development database,
and clears stale temporary files. Open <http://localhost:3000> after `bin/dev`
starts Puma and the Tailwind watcher.

Run the complete local quality gate from another terminal:

```bash
bin/ci
```

The default `.env.example` connects host Rails to the published PostgreSQL port
with synthetic `rails_sass` credentials. If port 5432 is occupied, choose a host
port in the ignored `.env`, then use the same value when starting PostgreSQL:

```bash
PGPORT=55432 docker compose up --detach --wait postgres
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
docker compose up --detach --wait postgres
docker compose build app
docker compose run --rm app bin/setup --skip-server
docker compose up app
```

Open <http://localhost:3000>. The app container uses the internal hostname
`postgres`; Compose overrides the host-oriented PG settings without changing
the tracked example or the ignored `.env`.

Run the same quality gate inside the development image with:

```bash
docker compose run --rm app bin/ci
```

The image defaults to UID/GID 1000 so bind-mounted files are not owned by root.
On a host with different IDs, rebuild with explicit values:

```bash
LOCAL_UID=$(id -u) LOCAL_GID=$(id -g) docker compose build app
```

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
bundle; database state and environment files are never cached. On failure, the
workflow retains `log/test.log` and any Capybara/system-test screenshots when
they exist.

After the quality gate succeeds, a dependent job builds the production image,
starts it with a dummy secret-key base and no deployment credentials, and checks
`/up`. This is an image smoke test, not a deployment workflow.

Dependabot checks Bundler, GitHub Actions, and Docker dependencies weekly.

## Database lifecycle and troubleshooting

Inspect service health and logs with:

```bash
docker compose ps
docker compose logs postgres
docker compose exec postgres pg_isready -U rails_sass -d rails_sass_development
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
