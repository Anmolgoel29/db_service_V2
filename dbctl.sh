#!/usr/bin/env bash
# dbctl.sh — the single entry point for the db farm.
#
# Stack:      up | down | restart | status | logs | pull | bootstrap
# Databases:  new | list | drop-db | extension
# Users:      add-user | users | passwd | drop-user
# Data:       psql | dsn | dump | restore
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT/.env"
CRED_DIR="$ROOT/credentials"
DUMP_DIR="$ROOT/dumps"

c_hi=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_hi" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '\033[31merror:%s %s\n' "$c_off" "$*" >&2; exit 1; }

load_env() {
  [[ -f $ENV_FILE ]] || die "no .env here — run ./setup.sh first"
  set -a; . "$ENV_FILE"; set +a
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD missing from .env}"
  BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
  POSTGRES_PORT="${POSTGRES_PORT:-5440}"
  PUBLIC_HOST="${PUBLIC_HOST:-$BIND_ADDR}"
}

# ── plumbing ────────────────────────────────────────────────────────────────

compose() {
  # COMPOSE_FILE in .env (e.g. to add an overlay) wins over the default file.
  if [[ -n ${COMPOSE_FILE:-} ]]; then
    docker compose --project-directory "$ROOT" "$@"
  else
    docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" "$@"
  fi
}

require_up() {
  compose ps --status running --services 2>/dev/null | grep -qx postgres \
    || die "the postgres container is not running — ./dbctl.sh up"
}

# psql as superuser over TCP inside the container: works no matter which user
# `docker compose exec` lands us on.
psql_su() { # <db> [psql args...]
  local db="$1"; shift
  compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d "$db" "$@"
}

# scalar / bare-tuple query
q() { local db="$1"; shift; psql_su "$db" -tAq -c "$*"; }

valid_ident() { [[ $1 =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }

need_ident() {
  valid_ident "$1" || die "invalid name '$1' — use lowercase letters, digits and _ (max 63, not starting with a digit)"
}

db_exists()   { [[ $(q postgres "SELECT 1 FROM pg_database WHERE datname = '$1'") == 1 ]]; }
role_exists() { [[ $(q postgres "SELECT 1 FROM pg_roles WHERE rolname = '$1'") == 1 ]]; }

gen_password() { openssl rand -hex 24; }

urlenc() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# CREATE/ALTER ROLE via format(%I,%L) so the password never lands in SQL text
create_role() { # <role> <password>
  psql_su postgres -q -v role="$1" -v pw="$2" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
\gexec
SQL
}

alter_role_password() { # <role> <password>
  psql_su postgres -q -v role="$1" -v pw="$2" <<'SQL'
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
\gexec
SQL
}

write_creds() { # <db> <user> <password>
  local db="$1" user="$2" pass="$3" enc f
  enc="$(urlenc "$pass")"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  f="$CRED_DIR/${db}.${user}.env"
  (
    umask 077
    cat >"$f" <<EOF
# written by dbctl.sh on $(date -Iseconds)
DB_NAME=$db
DB_USER=$user
DB_PASSWORD=$pass
DB_HOST=$PUBLIC_HOST
DB_PORT=$POSTGRES_PORT

# from another container on the \`dbfarm\` docker network
# (this is the one to paste into PG Back Web and pg-view)
DSN_INTERNAL=postgresql://$user:$enc@postgres:5432/$db?sslmode=disable

# from the docker host or anywhere that can reach $PUBLIC_HOST:$POSTGRES_PORT
DSN_HOST=postgresql://$user:$enc@$PUBLIC_HOST:$POSTGRES_PORT/$db
EOF
  )
  printf '%s\n' "$f"
}

show_creds() { # <db> <user>
  local f="$CRED_DIR/${1}.${2}.env"
  [[ -f $f ]] || die "no stored credentials for ${1}/${2} (looked in $f)"
  grep -v '^#' "$f" | grep -v '^$'
}

# ── stack ───────────────────────────────────────────────────────────────────

cmd_up() {
  compose up -d "$@"
  info "waiting for postgres to report healthy"
  local i
  for i in $(seq 1 60); do
    [[ $(docker inspect -f '{{.State.Health.Status}}' dbfarm-postgres 2>/dev/null) == healthy ]] && break
    sleep 2
  done
  cmd_status
}

cmd_down()    { compose down "$@"; }
cmd_restart() { compose restart "$@"; }
cmd_logs()    { compose logs -f --tail=200 "$@"; }
cmd_pull()    { compose pull "$@"; }

cmd_status() {
  compose ps
  if compose ps --status running --services 2>/dev/null | grep -qx postgres; then
    printf '\n%sdatabases%s\n' "$c_hi" "$c_off"
    cmd_list
  fi
  cat <<EOF

${c_hi}pg-view${c_off}     http://${BIND_ADDR}:${PGVIEW_PORT:-8040}
${c_hi}pgbackweb${c_off}   http://${BIND_ADDR}:${PGBACKWEB_PORT:-8045}
${c_hi}postgres${c_off}    ${PUBLIC_HOST}:${POSTGRES_PORT} ${c_dim}(superuser: postgres)${c_off}
EOF
}

# Replays init/10-farm-bootstrap.sh against a running instance — for data
# directories that predate it, or to resync the pgbackweb password with .env.
cmd_bootstrap() {
  require_up
  : "${PGBACKWEB_DB_PASSWORD:?PGBACKWEB_DB_PASSWORD missing from .env}"
  compose exec -T \
    -e PGBACKWEB_DB_PASSWORD="$PGBACKWEB_DB_PASSWORD" \
    -e POSTGRES_USER=postgres \
    -e PGHOST=127.0.0.1 \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres bash /docker-entrypoint-initdb.d/10-farm-bootstrap.sh
}

# ── databases ───────────────────────────────────────────────────────────────

cmd_new() {
  local db="" user="" pass="" with_ro=0
  db="${1:-}"; [[ -n $db ]] || die "usage: dbctl.sh new <db> [--user <user>] [--password <pw>] [--with-readonly]"
  shift
  while (($#)); do
    case $1 in
      --user)     user="${2:?--user needs a value}"; shift 2 ;;
      --password) pass="${2:?--password needs a value}"; shift 2 ;;
      --with-readonly) with_ro=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  need_ident "$db"
  user="${user:-$db}"
  need_ident "$user"
  pass="${pass:-$(gen_password)}"

  require_up
  db_exists "$db"     && die "database '$db' already exists"
  role_exists "$user" && die "role '$user' already exists — use 'add-user' to attach it to a database"

  info "creating role $user"
  create_role "$user" "$pass"

  info "creating database $db owned by $user"
  psql_su postgres -q <<SQL
CREATE DATABASE "$db" OWNER "$user";
REVOKE ALL ON DATABASE "$db" FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE "$db" TO "$user";
SQL

  # PUBLIC keeps USAGE on public so extensions stay usable; only CREATE and the
  # owner's grants are locked down.
  psql_su "$db" -q <<SQL
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO "$user";
SQL

  local f; f="$(write_creds "$db" "$user" "$pass")"
  printf '%s\n' "${c_ok}created${c_off} $db (owner $user) → credentials in ${f#"$ROOT"/}"

  if ((with_ro)); then
    cmd_add_user "$db" "${db}_ro" --read-only
  fi

  printf '\n%spaste into pg-view / PG Back Web:%s\n' "$c_hi" "$c_off"
  grep '^DSN_INTERNAL=' "$CRED_DIR/${db}.${user}.env" | cut -d= -f2-
}

cmd_list() {
  require_up
  psql_su postgres -c "
    SELECT d.datname                                   AS database,
           pg_get_userbyid(d.datdba)                   AS owner,
           pg_size_pretty(pg_database_size(d.datname))  AS size,
           (SELECT count(*) FROM pg_stat_activity a
             WHERE a.datname = d.datname)              AS conns
      FROM pg_database d
     WHERE NOT d.datistemplate
     ORDER BY 1;"
}

cmd_drop_db() {
  local db="${1:?usage: dbctl.sh drop-db <db> [--force]}" force="${2:-}"
  need_ident "$db"
  require_up
  db_exists "$db" || die "no such database: $db"
  [[ $db == pgbackweb || $db == postgres ]] && die "refusing to drop '$db' — it belongs to the farm itself"

  if [[ $force != --force ]]; then
    printf '%sthis destroys database "%s" and every table in it.%s\n' "$c_warn" "$db" "$c_off"
    read -rp "type the database name to confirm: " reply
    [[ $reply == "$db" ]] || die "aborted"
  fi
  psql_su postgres -q -c "DROP DATABASE \"$db\" WITH (FORCE);"
  rm -f "$CRED_DIR/$db".*.env
  info "dropped $db (its roles still exist — ./dbctl.sh drop-user <user>)"
}

cmd_extension() {
  local db="${1:?usage: dbctl.sh extension <db> <extension>}" ext="${2:?usage: dbctl.sh extension <db> <extension>}"
  need_ident "$db"
  [[ $ext =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid extension name"
  require_up
  psql_su "$db" -q -c "CREATE EXTENSION IF NOT EXISTS \"$ext\" CASCADE;"
  info "extension $ext ready in $db"
}

# ── users ───────────────────────────────────────────────────────────────────

cmd_add_user() {
  local db="${1:?usage: dbctl.sh add-user <db> <user> [--read-only|--read-write] [--password <pw>]}"
  local user="${2:?usage: dbctl.sh add-user <db> <user> [--read-only|--read-write] [--password <pw>]}"
  shift 2
  local mode=rw pass=""
  while (($#)); do
    case $1 in
      --read-only|--ro)  mode=ro; shift ;;
      --read-write|--rw) mode=rw; shift ;;
      --password) pass="${2:?--password needs a value}"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  need_ident "$db"; need_ident "$user"
  require_up
  db_exists "$db" || die "no such database: $db"

  local owner
  owner="$(q postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'")"

  if role_exists "$user"; then
    info "role $user exists — granting it access to $db"
    [[ -n $pass ]] && { alter_role_password "$user" "$pass"; }
  else
    pass="${pass:-$(gen_password)}"
    info "creating role $user"
    create_role "$user" "$pass"
  fi

  psql_su postgres -q -c "GRANT CONNECT ON DATABASE \"$db\" TO \"$user\";"

  if [[ $mode == ro ]]; then
    psql_su "$db" -q <<SQL
GRANT USAGE ON SCHEMA public TO "$user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$user";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "$user";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT SELECT ON TABLES TO "$user";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT SELECT ON SEQUENCES TO "$user";
SQL
  else
    psql_su "$db" -q <<SQL
GRANT USAGE, CREATE ON SCHEMA public TO "$user";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "$user";
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "$user";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT ALL ON TABLES TO "$user";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT ALL ON SEQUENCES TO "$user";
SQL
  fi

  if [[ -n $pass ]]; then
    local f; f="$(write_creds "$db" "$user" "$pass")"
    printf '%s\n' "${c_ok}granted${c_off} $user → $db ($mode) → credentials in ${f#"$ROOT"/}"
  else
    printf '%s\n' "${c_ok}granted${c_off} $user → $db ($mode) ${c_dim}(password unchanged)${c_off}"
  fi
}

cmd_users() {
  require_up
  psql_su postgres -c "
    SELECT r.rolname                                              AS role,
           r.rolsuper                                             AS superuser,
           coalesce(string_agg(d.datname, ', ' ORDER BY d.datname), '-') AS owns
      FROM pg_roles r
      LEFT JOIN pg_database d ON d.datdba = r.oid
     WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
     GROUP BY 1, 2
     ORDER BY 1;"
}

cmd_passwd() {
  local user="${1:?usage: dbctl.sh passwd <user> [password]}" pass="${2:-}"
  need_ident "$user"
  require_up
  role_exists "$user" || die "no such role: $user"
  pass="${pass:-$(gen_password)}"
  alter_role_password "$user" "$pass"
  info "password changed for $user"

  # refresh every stored credentials file for this role
  local f db
  shopt -s nullglob
  for f in "$CRED_DIR"/*."$user".env; do
    db="$(basename "$f")"; db="${db%".$user.env"}"
    write_creds "$db" "$user" "$pass" >/dev/null
    printf '  updated credentials/%s\n' "$(basename "$f")"
  done
  shopt -u nullglob
  printf '%snew password:%s %s\n' "$c_hi" "$c_off" "$pass"
  warn "restart anything still holding the old password"
}

cmd_drop_user() {
  local user="${1:?usage: dbctl.sh drop-user <user> [--force]}" force="${2:-}"
  need_ident "$user"
  require_up
  role_exists "$user" || die "no such role: $user"
  [[ $user == postgres || $user == pgbackweb ]] && die "refusing to drop '$user' — it belongs to the farm itself"

  local owned
  owned="$(q postgres "SELECT string_agg(datname, ', ') FROM pg_database WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$user')")"
  [[ -n $owned ]] && die "$user still owns database(s): $owned — drop those first"

  if [[ $force != --force ]]; then
    printf '%sdropping %s also drops every object it owns inside each database.%s\n' "$c_warn" "$user" "$c_off"
    read -rp "type the role name to confirm: " reply
    [[ $reply == "$user" ]] || die "aborted"
  fi

  local d
  for d in $(q postgres "SELECT datname FROM pg_database WHERE NOT datistemplate"); do
    psql_su "$d" -q -c "DROP OWNED BY \"$user\";" 2>/dev/null || true
  done
  psql_su postgres -q -c "DROP ROLE \"$user\";"
  rm -f "$CRED_DIR"/*."$user".env
  info "dropped role $user"
}

# ── data ────────────────────────────────────────────────────────────────────

cmd_psql() {
  local db="${1:-postgres}"; shift || true
  require_up
  compose exec -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    psql -h 127.0.0.1 -U postgres -d "$db" "$@"
}

cmd_dsn() {
  local db="${1:?usage: dbctl.sh dsn <db> [user]}" user="${2:-$1}"
  show_creds "$db" "$user"
}

cmd_dump() {
  local db="${1:?usage: dbctl.sh dump <db> [outfile]}"
  need_ident "$db"
  require_up
  db_exists "$db" || die "no such database: $db"
  mkdir -p "$DUMP_DIR"
  local out="${2:-$DUMP_DIR/${db}-$(date +%Y%m%d-%H%M%S).dump}"
  compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    pg_dump -h 127.0.0.1 -U postgres -Fc -d "$db" >"$out"
  printf '%s\n' "${c_ok}dumped${c_off} $db → $out ($(du -h "$out" | cut -f1))"
}

cmd_restore() {
  local db="${1:?usage: dbctl.sh restore <db> <file.dump>}" file="${2:?usage: dbctl.sh restore <db> <file.dump>}"
  need_ident "$db"
  [[ -f $file ]] || die "no such file: $file"
  require_up
  db_exists "$db" || die "no such database: $db — create it first with 'new'"
  printf '%srestoring into "%s" overwrites objects it already holds.%s\n' "$c_warn" "$db" "$c_off"
  read -rp "type the database name to confirm: " reply
  [[ $reply == "$db" ]] || die "aborted"
  compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    pg_restore -h 127.0.0.1 -U postgres -d "$db" --clean --if-exists --no-owner <"$file"
  info "restored $file into $db"
}

# ── dispatch ────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${c_hi}dbctl.sh${c_off} — one postgres instance, many databases

${c_hi}stack${c_off}
  up [svc...]                     start (waits for postgres to be healthy)
  down [--volumes]                stop
  restart [svc...]                restart
  status                          containers, databases, URLs
  logs [svc]                      follow logs
  pull                            pull newer images
  bootstrap                       (re)create the pgbackweb role + database

${c_hi}databases${c_off}
  new <db> [--user U] [--password P] [--with-readonly]
                                  role + database + credentials file
  list                            databases with owner, size, connections
  drop-db <db> [--force]
  extension <db> <ext>            CREATE EXTENSION as superuser

${c_hi}users${c_off}
  add-user <db> <user> [--read-only|--read-write] [--password P]
  users                           login roles and what they own
  passwd <user> [password]        rotate (rewrites credentials/)
  drop-user <user> [--force]

${c_hi}data${c_off}
  psql [db]                       interactive superuser shell
  dsn <db> [user]                 stored connection strings
  dump <db> [outfile]             pg_dump -Fc into dumps/
  restore <db> <file.dump>

${c_dim}credentials/ holds one file per role — gitignored, chmod 600.${c_off}
EOF
}

cmd="${1:-status}"; shift || true

# help is the one thing that works before ./setup.sh has run
case "$cmd" in
  -h|--help|help) usage; exit 0 ;;
esac
load_env

case "$cmd" in
  up)        cmd_up "$@" ;;
  down)      cmd_down "$@" ;;
  restart)   cmd_restart "$@" ;;
  status|ps) cmd_status ;;
  logs)      cmd_logs "$@" ;;
  pull)      cmd_pull "$@" ;;
  bootstrap) cmd_bootstrap ;;
  new)       cmd_new "$@" ;;
  list|ls)   cmd_list ;;
  drop-db)   cmd_drop_db "$@" ;;
  extension) cmd_extension "$@" ;;
  add-user)  cmd_add_user "$@" ;;
  users)     cmd_users ;;
  passwd)    cmd_passwd "$@" ;;
  drop-user) cmd_drop_user "$@" ;;
  psql)      cmd_psql "$@" ;;
  dsn)       cmd_dsn "$@" ;;
  dump)      cmd_dump "$@" ;;
  restore)   cmd_restore "$@" ;;
  *)         usage; die "unknown command: $cmd" ;;
esac
