#!/usr/bin/env bash
# migrate-tenant.sh — stream one tenant's `public` schema (no Supabase
# auth/storage/realtime schemas, no ACLs) straight from a db_service (V1)
# instance into a same-named database on db_service_V2. One pipe, no
# intermediate .dump file.
#
#   ./migrate-tenant.sh <tenant>              schema + data
#                                              (use on a tenant with no schema
#                                              in V2 yet — nothing to collide with)
#
#   ./migrate-tenant.sh <tenant> --data-only  data only
#                                              (use after you've run your own
#                                              migrations against V2 to build
#                                              the schema — this just loads rows)
#
# Assumes both stacks are checked out side by side (../db_service by default
# — override with V1_ROOT=/path/to/db_service) and this host has docker
# access to both. Run with sudo -E if you're not in the docker group (see
# db_service/README.md "Prerequisites").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="${V1_ROOT:-$ROOT/../db_service}"

c_hi=$'\033[36m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_hi" "$c_off" "$*"; }
die()  { printf '\033[31merror:%s %s\n' "$c_off" "$*" >&2; exit 1; }

# docker compose against the V2 stack (mirrors dbctl.sh's own helper).
compose_v2() {
  if [[ -n ${COMPOSE_FILE:-} ]]; then
    docker compose --project-directory "$ROOT" "$@"
  else
    docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" "$@"
  fi
}

tenant="${1:?usage: migrate-tenant.sh <tenant> [--data-only]}"
mode="${2:-}"

v1_dir="$V1_ROOT/tenants/$tenant"
[ -d "$v1_dir" ] || die "no such V1 tenant dir: $v1_dir"

env_get() { grep "^${2}=" "$1/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
pg_port="$(env_get "$v1_dir" POSTGRES_PORT)"
[ -n "$pg_port" ] || die "couldn't read POSTGRES_PORT from $v1_dir/.env"

set -a; . "$ROOT/.env"; set +a
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD missing from $ROOT/.env}"

# --no-owner --no-privileges: strip OWNER TO / GRANT statements. V1's dump
# would otherwise reference Supabase-only roles (anon, authenticated,
# service_role) that don't exist in the plain V2 farm and blow up on the
# first GRANT.
dump_flags=(--schema=public --no-owner --no-privileges)
case "$mode" in
  --data-only)
    # --disable-triggers brackets each table's data with
    # ALTER TABLE ... DISABLE/ENABLE TRIGGER ALL, so FK-enforcement triggers
    # can't block load order (needed for e.g. chat_chatmessage's circular FK).
    # --inserts --on-conflict-do-nothing: your own migrations already ran
    # against V2 and some tables (Django's django_content_type,
    # auth_permission, ...) get pre-seeded rows as a side effect. Row-by-row
    # INSERT ... ON CONFLICT DO NOTHING skips exactly those collisions at the
    # SQL level instead of aborting the whole table's load — real errors
    # (missing column, wrong type, etc.) still stop the script.
    dump_flags+=(--data-only --disable-triggers --inserts --on-conflict-do-nothing)
    info "streaming DATA ONLY for '$tenant': V1 -> V2 (schema must already exist there — e.g. from your migrations)"
    ;;
  "")
    # --clean --if-exists: every fresh Postgres database already has a
    # `public` schema (dbctl.sh new just created one), so the incoming
    # `CREATE SCHEMA public;` collides unless we drop-and-recreate it first.
    # Also makes a re-run of this script safe/idempotent.
    dump_flags+=(--clean --if-exists)
    info "streaming schema + data for '$tenant': V1 -> V2"
    ;;
  *)
    die "unknown flag: $mode"
    ;;
esac

if ! "$ROOT/dbctl.sh" new "$tenant" 2>/dev/null; then
  info "database '$tenant' already exists in V2"
fi

( cd "$v1_dir" && docker compose exec -T db \
    pg_dump -U postgres -p "$pg_port" -d postgres "${dump_flags[@]}" ) \
  | compose_v2 exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
      psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d "$tenant"

if [[ $mode == "" ]]; then
  # The load above connected (and therefore created every object) as the
  # `postgres` superuser, since --no-owner strips the original OWNER TO
  # statements. Left alone, `postgres` would own goelneha's tables instead of
  # goelneha's own role — hand every object in `public` over and reapply
  # dbctl.sh new's schema-level lockdown (CREATE on public revoked from PUBLIC)
  # that dropping/recreating the schema just reset to Postgres's defaults.
  #
  # Deliberately NOT `REASSIGN OWNED BY postgres TO <tenant>`: `postgres` is the
  # bootstrap superuser, so it also owns pinned catalog objects, and REASSIGN
  # OWNED is all-or-nothing over everything a role owns. It always dies with
  #   cannot reassign ownership of objects owned by role postgres
  #   because they are required by the database system
  # before it ever reaches the tenant's tables. Walking `public` and emitting
  # one ALTER ... OWNER TO per object (psql's \gexec runs each row of the
  # result as SQL) touches only what this migration actually created.
  info "reassigning ownership in '$tenant' from postgres to $tenant"
  compose_v2 exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -q -h 127.0.0.1 -U postgres -d "$tenant" \
         -v owner="$tenant" <<'SQL'
SELECT format('ALTER SCHEMA public OWNER TO %I', :'owner')
WHERE (SELECT nspowner FROM pg_namespace WHERE nspname = 'public') <> :'owner'::regrole
\gexec

-- Tables, views, matviews, sequences, foreign tables. ALTER TABLE carries a
-- table's indexes, TOAST table and owned (serial/identity) sequences with it,
-- so the sequence rows below are usually already no-ops by the time they run.
-- The pg_depend 'e' filter here and in the two queries after it skips objects
-- that belong to an extension (pgcrypto, uuid-ossp, postgis' spatial_ref_sys):
-- those are the farm's to own, not the tenant's.
SELECT format('ALTER %s %I.%I OWNER TO %I',
              CASE c.relkind WHEN 'r' THEN 'TABLE'
                             WHEN 'p' THEN 'TABLE'
                             WHEN 'f' THEN 'FOREIGN TABLE'
                             WHEN 'v' THEN 'VIEW'
                             WHEN 'm' THEN 'MATERIALIZED VIEW'
                             WHEN 'S' THEN 'SEQUENCE' END,
              n.nspname, c.relname, :'owner')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S')
  AND c.relowner <> :'owner'::regrole
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_class'::regclass
                    AND d.objid = c.oid AND d.deptype = 'e')
ORDER BY (c.relkind = 'S'), c.relname
\gexec

-- Functions, procedures and aggregates.
SELECT format('ALTER ROUTINE %s OWNER TO %I', p.oid::regprocedure, :'owner')
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proowner <> :'owner'::regrole
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_proc'::regclass
                    AND d.objid = p.oid AND d.deptype = 'e')
\gexec

-- Enums, domains, ranges and standalone composite types. Excluded: the array
-- and table row types Postgres derives from the objects above, and multirange
-- types, which Postgres refuses to alter directly (altering the range type
-- they belong to moves them too).
SELECT format('ALTER %s %s OWNER TO %I',
              CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
              t.oid::regtype, :'owner')
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'public'
  AND t.typowner <> :'owner'::regrole
  AND t.typtype IN ('b', 'c', 'd', 'e', 'r')
  AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind <> 'c')
  AND NOT EXISTS (SELECT 1 FROM pg_type el WHERE el.oid = t.typelem AND el.typarray = t.oid)
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_type'::regclass
                    AND d.objid = t.oid AND d.deptype = 'e')
\gexec

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO :"owner";
SQL
fi

info "done: $tenant"

cat <<EOF

${c_hi}next${c_off}
  ./dbctl.sh psql $tenant -c '\dt'      # sanity check: tables landed
  ./dbctl.sh dsn  $tenant               # connection string for the app

If it stopped on a missing function (gen_random_uuid(), uuid_generate_v4()),
that table depends on an extension Supabase installed into its own
'extensions' schema — create it in V2, then re-run:
  ./dbctl.sh extension $tenant pgcrypto
  ./dbctl.sh extension $tenant "uuid-ossp"

If it stopped on CREATE POLICY / a rule calling auth.uid() or auth.role(),
that table still depends on Supabase Auth's schema — V2 has no auth service
to back it, so drop or rewrite that policy in your migrations.
EOF
