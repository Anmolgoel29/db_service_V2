#!/usr/bin/env bash
# migrate-tenant.sh — copy one tenant's `public` schema (schema + data only;
# no Supabase auth/storage/realtime schemas, no ACLs) from a db_service (V1)
# instance into a same-named database on db_service_V2.
#
#   ./migrate-tenant.sh <tenant>                    dump from V1, create + restore into V2
#   ./migrate-tenant.sh <tenant> --dump-only         just write dumps/<tenant>-public-<ts>.dump
#   ./migrate-tenant.sh <tenant> --restore-only FILE restore an existing dump into V2
#
# Assumes both stacks are checked out side by side (../db_service by
# default — override with V1_ROOT=/path/to/db_service) and that this host
# has docker access to both. Run with sudo -E if you're not in the docker
# group (see db_service/README.md "Prerequisites").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="${V1_ROOT:-$ROOT/../db_service}"
DUMP_DIR="$ROOT/dumps"

c_hi=$'\033[36m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_hi" "$c_off" "$*"; }
die()  { printf '\033[31merror:%s %s\n' "$c_off" "$*" >&2; exit 1; }

tenant="${1:?usage: migrate-tenant.sh <tenant> [--dump-only|--restore-only FILE]}"
mode="${2:-}"

v1_dir="$V1_ROOT/tenants/$tenant"

env_get() { grep "^${2}=" "$1/.env" 2>/dev/null | head -1 | cut -d= -f2-; }

do_dump() {
  [ -d "$v1_dir" ] || die "no such V1 tenant dir: $v1_dir"
  local pg_port
  pg_port="$(env_get "$v1_dir" POSTGRES_PORT)"
  [ -n "$pg_port" ] || die "couldn't read POSTGRES_PORT from $v1_dir/.env"

  mkdir -p "$DUMP_DIR"
  dump_file="$DUMP_DIR/${tenant}-public-$(date +%Y%m%d-%H%M%S).dump"

  info "dumping public schema of '$tenant' from db_service (V1)"
  # --no-owner --no-privileges: strip OWNER TO / GRANT statements. The V1 dump
  # would otherwise reference Supabase-only roles (anon, authenticated,
  # service_role) that don't exist in the plain V2 farm, and restore would
  # fail on the first GRANT.
  ( cd "$v1_dir" && docker compose exec -T db \
      pg_dump -U postgres -p "$pg_port" -d postgres \
        --schema=public --no-owner --no-privileges -Fc \
  ) > "$dump_file"
  info "dumped -> ${dump_file#"$ROOT"/} ($(du -h "$dump_file" | cut -f1))"
}

do_restore() {
  local file="$1"
  [ -f "$file" ] || die "no such dump file: $file"

  if "$ROOT/dbctl.sh" new "$tenant" 2>/dev/null; then
    :
  else
    info "database '$tenant' already exists in V2 — restoring into it"
  fi

  info "restoring $file into V2/$tenant"
  # dbctl.sh restore asks for interactive confirmation (types the db name);
  # feed it since we already know the target.
  echo "$tenant" | "$ROOT/dbctl.sh" restore "$tenant" "$file"
}

case "$mode" in
  --dump-only)
    do_dump
    ;;
  --restore-only)
    file="${3:?usage: migrate-tenant.sh <tenant> --restore-only FILE}"
    do_restore "$file"
    ;;
  "")
    do_dump
    do_restore "$dump_file"
    ;;
  *)
    die "unknown mode: $mode"
    ;;
esac

cat <<EOF

${c_hi}next${c_off}
  ./dbctl.sh psql $tenant -c '\dt'      # sanity check: tables landed
  ./dbctl.sh dsn  $tenant               # connection string for the app

If restore fails on a missing function (e.g. gen_random_uuid(),
uuid_generate_v4()), the table depends on an extension Supabase installed
into its own 'extensions' schema — create it in V2 first, then re-run
--restore-only:
  ./dbctl.sh extension $tenant pgcrypto
  ./dbctl.sh extension $tenant "uuid-ossp"

If restore fails on a CREATE POLICY / RLS statement calling auth.uid() or
auth.role(), that table still depends on Supabase Auth's schema — drop or
rewrite that policy before/after restore, since V2 has no auth service to
back it.
EOF
