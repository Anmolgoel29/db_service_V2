# db_service_V2 — one Postgres, many databases

A minimal database farm. Three containers, no per-tenant stacks:

| Container | What it is | Why |
|---|---|---|
| `dbfarm-postgres` | Postgres 18 | every tenant is a **database + role** inside it, not a separate instance |
| `dbfarm-pgview` | [pg-view](https://pg-view.com/) | browse/edit tables, SQL editor, saved connections |
| `dbfarm-pgbackweb` | [PG Back Web](https://github.com/eduardolat/pgbackweb) | scheduled `pg_dump`s, retention, restore UI, S3/R2 upload |

This is the opposite trade from [db_service](../db_service) (V1), which runs a
full self-hosted Supabase stack **per tenant** — ~10 containers each, isolated
but heavy. Here you manage one instance and pay for isolation with SQL
privileges instead of containers. No PostgREST, no auth, no realtime: this is a
plain database with a UI and backups.

## Layout

```
docker-compose.yml          the three services
.env.example                every knob; ./setup.sh turns it into .env
setup.sh                    generates secrets, creates the bind-mount dirs
dbctl.sh                    the entry point — databases, users, dumps, stack
init/                       runs once on first boot (creates pgbackweb's own db)
volumes/postgres            PGDATA          ─┐
volumes/pg-view             saved connections│ gitignored
backups/                    local backups    │
dumps/                      ad-hoc pg_dumps  │
credentials/                one file per role┘ chmod 600
```

## Quick start

```sh
./setup.sh                      # writes .env with generated secrets
$EDITOR .env                    # check PG_VERSION, TZ, ports  ← see "Version matching"
./dbctl.sh up
./dbctl.sh new myapp --with-readonly
```

The last command prints a connection string and writes
`credentials/myapp.myapp.env`:

```
DB_NAME=myapp
DB_USER=myapp
DB_PASSWORD=6f3c…
DSN_INTERNAL=postgresql://myapp:6f3c…@postgres:5432/myapp?sslmode=disable
DSN_HOST=postgresql://myapp:6f3c…@127.0.0.1:5440/myapp
```

Two DSNs because there are two vantage points. `DSN_INTERNAL` uses the docker
hostname `postgres` — that is the one pg-view and PG Back Web need, since they
sit on the same network. `DSN_HOST` is for your app, `psql`, a GUI on your
laptop.

## Ports

Deliberately off the defaults so this stack can run beside V1, which already
holds `5432-5434`, `6543-6545` and `8000/8010/8020`.

| Service | Bound to | Change with |
|---|---|---|
| Postgres | `127.0.0.1:5440` | `POSTGRES_PORT` |
| pg-view | `127.0.0.1:8040` | `PGVIEW_PORT` |
| PG Back Web | `127.0.0.1:8045` | `PGBACKWEB_PORT` |

Everything binds to loopback. To let other machines reach Postgres directly set
`BIND_ADDR=0.0.0.0` **and** `PUBLIC_HOST=<your host or domain>` so the generated
DSNs are correct — then put a firewall in front of 5440.

## Databases and users

```sh
./dbctl.sh new crm                       # role crm owns database crm
./dbctl.sh new crm --user crm_app        # different role name
./dbctl.sh new crm --with-readonly       # also creates crm_ro (SELECT only)

./dbctl.sh add-user crm analytics --read-only
./dbctl.sh add-user crm worker --read-write
./dbctl.sh passwd crm_app                # rotate, rewrites credentials/
./dbctl.sh users                         # who exists, what they own
./dbctl.sh list                          # databases, owners, sizes, conns

./dbctl.sh extension crm pgcrypto        # CREATE EXTENSION as superuser
./dbctl.sh psql crm                      # superuser shell
./dbctl.sh dsn crm crm_ro                # print stored credentials
./dbctl.sh dump crm                      # → dumps/crm-20260824-231500.dump
./dbctl.sh restore crm dumps/crm-….dump
```

What `new` actually does, and why isolation holds in a shared instance:

- creates the role, then the database **owned by that role**;
- `REVOKE ALL ON DATABASE … FROM PUBLIC` — without this every role in the
  instance could `CONNECT` to every database, which is the whole risk of a
  farm;
- `REVOKE CREATE ON SCHEMA public FROM PUBLIC` (also applied to `template1` at
  first boot, so new databases inherit it);
- since Postgres 15 the `public` schema is owned by `pg_database_owner`, so the
  database owner gets full rights on it and nobody else does.

Read-only users get `SELECT` on today's tables *and* `ALTER DEFAULT PRIVILEGES`
for tables the owner creates tomorrow — otherwise every migration silently
locks them out.

Names are validated against `^[a-z_][a-z0-9_]{0,62}$`; passwords are 24 random
bytes of hex, which need no URL escaping in a DSN.

## pg-view

`http://127.0.0.1:8040` — log in with `PGVIEW_USERNAME` / `PGVIEW_PASSWORD`
from `.env`.

It starts with one connection seeded from `DB_URL`: the maintenance database as
superuser. Add each tenant from the UI, pasting the `DSN_INTERNAL` line from
`./dbctl.sh dsn <db> <user>`. Connections and SQL history persist in
`volumes/pg-view`.

For a browsing-only panel set `PGVIEW_READ_ONLY=true` and restart — it refuses
every write regardless of what the connection's role is allowed to do. Prefer
saving a `_ro` role's DSN when you want per-connection safety instead.

## PG Back Web

`http://127.0.0.1:8045` — the first visit creates the admin account.

**1. Destination** (Cloudflare R2). Add an S3-compatible destination:

| Field | Value |
|---|---|
| Endpoint | `https://<account-id>.r2.cloudflarestorage.com` |
| Region | `auto` |
| Bucket | your R2 bucket |
| Access key / secret | from an R2 API token scoped to that bucket |

Any S3-compatible target works the same way. `backups/` is the local
destination and stays empty if you only use R2.

**2. Database.** Add each database with its `DSN_INTERNAL` (host `postgres`),
and pick the matching Postgres version for the dump.

**3. Backup.** Cron schedule, destination, retention, and whether the dump is
compressed. Schedules run in `TZ` from `.env` — `Asia/Kolkata` by default, so
`0 3 * * *` means 3am local, not 3am UTC.

**4. Restore.** Backups tab → restore → choose a target connection. Restoring
into the *source* database overwrites it; restoring into a fresh one you made
with `./dbctl.sh new` is the safer drill. Do that drill once now rather than
discovering a broken chain during an incident.

### Version matching

PG Back Web ships `pg_dump` for a fixed set of majors (13–18 as of 0.5.1) and a
dump must be taken by a `pg_dump` at least as new as the server. Confirm what
your image actually carries **before first start**:

```sh
docker run --rm --entrypoint sh eduardolat/pgbackweb:0.5.1 \
  -c 'find / -maxdepth 6 -name "pg_dump*" 2>/dev/null'
```

If 18 is missing, set `PG_VERSION=17` in `.env` before the first `./dbctl.sh
up`. Changing the major *after* the data directory exists is not a restart — it
is a dump, wipe `volumes/postgres`, and restore.

### The one circular dependency

PG Back Web keeps its schedules, destinations and history in a `pgbackweb`
database **on the instance it backs up**. That is the cost of "one instance to
manage", and it has two consequences worth handling:

- **Back up `pgbackweb` itself**, to R2, on a schedule like everything else.
  Otherwise a lost instance takes the backup catalogue with it — the dumps in
  R2 survive, but you rebuild the schedules by hand.
- **Keep `PGBACKWEB_ENCRYPTION_KEY` off this host.** Destination keys and saved
  connection strings are encrypted with it; without it a restored `pgbackweb`
  database is useless. `setup.sh` says the same thing on the way out.

If you would rather break the loop, point `PBW_POSTGRES_CONN_STRING` at a
second small Postgres container — one extra container, no shared fate.

## Exposing the UIs

`BIND_ADDR=0.0.0.0` publishes Postgres, pg-view, and PG Back Web directly on
the server's public IP (`PUBLIC_HOST`) with no proxy or tunnel in front. All
three still require their own login/password, but there is nothing else
between them and the internet — treat the passwords in `.env` and
`credentials/` accordingly, and consider a host firewall restricting the ports
to known source IPs if that becomes an option later.

## Operations

```sh
./dbctl.sh status         # containers + databases + URLs
./dbctl.sh logs postgres
./dbctl.sh pull && ./dbctl.sh up      # update images
./dbctl.sh down                       # stop (data survives)
```

`pg-view` only publishes a `latest` tag; pin it by digest in `.env`
(`PGVIEW_VERSION=latest@sha256:…`) if you want reproducible restarts.

Tuning lives in `.env` and is applied as `-c` flags: `shared_buffers` ~25% of
RAM, `effective_cache_size` ~75%, `work_mem` small — it is allocated per sort,
per connection, so 200 connections × 8MB is the number that matters.

`init/` runs only against an empty data directory. `./dbctl.sh bootstrap`
replays it against a live instance (idempotent; also resyncs the `pgbackweb`
role password with `.env`).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `postgres container is not running` | `./dbctl.sh up`; if it exits, `./dbctl.sh logs postgres` |
| pgbackweb restarts in a loop | wrong `PGBACKWEB_DB_PASSWORD` vs the role — `./dbctl.sh bootstrap` |
| `password authentication failed` from an app | rotated password; re-read `credentials/<db>.<user>.env` |
| pg-view can't reach a database | used `DSN_HOST` instead of `DSN_INTERNAL` (host must be `postgres`) |
| Backup fails on version mismatch | see "Version matching" |
| `permission denied for schema public` | non-owner role without a grant — `./dbctl.sh add-user <db> <user> --read-write` |
