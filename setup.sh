#!/usr/bin/env bash
# One-time bootstrap: generate .env with fresh secrets and create the
# directories the bind mounts expect. Safe to re-run; it never touches an
# existing .env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

c_ok=$'\033[32m'; c_hi=$'\033[36m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_hi" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found"
command -v openssl >/dev/null || die "openssl not found (needed to generate secrets)"

# hex only: these end up inside URLs, where a stray @ / : / # would split the DSN
gen() { openssl rand -hex "${1:-24}"; }

set_val() { # set_val KEY VALUE  (in .env)
  local key="$1" val="$2"
  grep -q "^${key}=" .env || die "key ${key} missing from .env.example"
  # value is generated hex or a literal from .env.example — no sed metachars
  sed -i "s|^${key}=.*|${key}=${val}|" .env
}

if [[ -f .env ]]; then
  info ".env already exists — leaving it alone"
  if grep -qE '^[A-Z0-9_]+=CHANGE_ME' .env; then
    warn "it still contains CHANGE_ME placeholders:"
    grep -nE '^[A-Z0-9_]+=CHANGE_ME' .env | sed 's/^/      /'
    warn "fill them in, or delete .env and re-run this script"
  fi
else
  [[ -f .env.example ]] || die ".env.example is missing"
  info "writing .env with generated secrets"
  cp .env.example .env
  chmod 600 .env
  set_val POSTGRES_PASSWORD          "$(gen 24)"
  set_val PGBACKWEB_DB_PASSWORD      "$(gen 24)"
  set_val PGBACKWEB_ENCRYPTION_KEY   "$(gen 32)"
  set_val PGVIEW_PASSWORD            "$(gen 16)"
  set_val PGVIEW_SESSION_SECRET      "$(gen 32)"

  # BIND_ADDR=0.0.0.0 in .env.example publishes on this box's public IP; fill
  # PUBLIC_HOST with it so the generated DSNs point somewhere reachable.
  public_ip="$(curl -s -4 --max-time 5 ifconfig.me || true)"
  if [[ $public_ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    set_val PUBLIC_HOST "$public_ip"
    info "detected public IP $public_ip — set as PUBLIC_HOST"
  else
    warn "couldn't auto-detect a public IP — set PUBLIC_HOST in .env by hand"
  fi
fi

info "creating data directories"
mkdir -p volumes/postgres volumes/pg-view backups dumps credentials
chmod 700 credentials

# The pg-view and pgbackweb images run as non-root; a root-owned bind mount
# would leave them unable to write their state.
chmod 777 volumes/pg-view backups 2>/dev/null || true

cat <<EOF

${c_ok}ready${c_off}

  1. review    ${c_hi}\$EDITOR .env${c_off}          ports, timezone, tuning
  2. start     ${c_hi}./dbctl.sh up${c_off}
  3. first db  ${c_hi}./dbctl.sh new myapp${c_off}

  pg-view      http://127.0.0.1:$(grep '^PGVIEW_PORT=' .env | cut -d= -f2)     login: $(grep '^PGVIEW_USERNAME=' .env | cut -d= -f2) / $(grep '^PGVIEW_PASSWORD=' .env | cut -d= -f2)
  pgbackweb    http://127.0.0.1:$(grep '^PGBACKWEB_PORT=' .env | cut -d= -f2)     first visit creates the admin account

  ${c_warn}Back up PGBACKWEB_ENCRYPTION_KEY from .env somewhere off this host —
  without it PG Back Web cannot decrypt its saved destinations.${c_off}

EOF
