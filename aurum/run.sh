#!/usr/bin/env bash
#
# Entrypoint for the Aurum Home Assistant add-on.
#
# Aurum upstream runs as three containers; this script runs the same three
# roles inside this one container:
#
#   1. read the Supervisor options from /data/options.json into the AURUM_*
#      environment variables the backend expects;
#   2. initialise the PostgreSQL data directory under /data (persistent) and
#      start Postgres bound to 127.0.0.1 only;
#   3. apply the database migrations and start the FastAPI backend on
#      127.0.0.1:8000;
#   4. generate the nginx basic-auth / allowed-hosts fragments from the
#      upstream docker-entrypoint.d scripts;
#   5. start nginx (the published port) and stay in the foreground.
#
# /data is persistent across add-on restarts, reinstalls and updates, so the
# Postgres data directory below is the one thing that keeps every account,
# transaction and setting between runs.

set -euo pipefail

readonly APPDIR=/opt/aurum/backend
readonly CONFIG_PATH=/data/options.json

# Postgres binary dir depends on the Debian release the base image ships
# (bookworm -> 15, trixie -> 17): resolve it instead of pinning a version.
PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
: "${PG_BIN:?no Postgres binaries found under /usr/lib/postgresql}"
readonly PG_BIN
readonly PG_DATA=/data/aurum-db

export PATH="${PG_BIN}:${PATH}"

log()  { echo "[aurum] $*"; }
warn() { echo "[aurum] WARNING: $*" >&2; }

# --- 1. Options ------------------------------------------------------------

# Map the Supervisor-provided options onto the exact AURUM_* variable names
# Aurum's backend reads (backend/app/core/config.py, env_prefix "AURUM_").
# jq defaults keep the add-on usable even when an option is new or left blank
# after an upgrade.
AURUM_POSTGRES_USER="${AURUM_POSTGRES_USER:-aurum}"
AURUM_POSTGRES_DB="$(jq -r '.postgres_db // "aurum"' "$CONFIG_PATH")"
AURUM_POSTGRES_PASSWORD="$(jq -r '.postgres_password // ""' "$CONFIG_PATH")"
AURUM_DEFAULT_CURRENCY="$(jq -r '.default_currency // "USD"' "$CONFIG_PATH")"
AURUM_COINGECKO_API_KEY="$(jq -r '.coingecko_api_key // ""' "$CONFIG_PATH")"
AURUM_ENABLE_DOCS="$(jq -r '.enable_docs // true' "$CONFIG_PATH")"
AURUM_CORS_ORIGINS="$(jq -r '.cors_origins // ""' "$CONFIG_PATH")"
AURUM_BASIC_AUTH_USER="$(jq -r '.basic_auth_user // ""' "$CONFIG_PATH")"
AURUM_BASIC_AUTH_PASSWORD="$(jq -r '.basic_auth_password // ""' "$CONFIG_PATH")"
AURUM_ALLOWED_HOSTS="$(jq -r '.allowed_hosts // "*"' "$CONFIG_PATH")"

export AURUM_POSTGRES_USER \
       AURUM_POSTGRES_DB \
       AURUM_POSTGRES_PASSWORD \
       AURUM_POSTGRES_HOST=127.0.0.1 \
       AURUM_POSTGRES_PORT=5432 \
       AURUM_DEFAULT_CURRENCY \
       AURUM_COINGECKO_API_KEY \
       AURUM_ENABLE_DOCS \
       AURUM_CORS_ORIGINS \
       AURUM_BASIC_AUTH_USER \
       AURUM_BASIC_AUTH_PASSWORD \
       AURUM_ALLOWED_HOSTS

# Aurum has no built-in login, but Postgres needs a password. When the option
# is left blank, generate one and keep it in /data so the value stays stable
# across restarts (Supervisor logs are only visible to an administrator).
if [ -z "$AURUM_POSTGRES_PASSWORD" ]; then
  if [ -f /data/.aurum-postgres-password ]; then
    AURUM_POSTGRES_PASSWORD="$(< /data/.aurum-postgres-password)"
  else
    AURUM_POSTGRES_PASSWORD="$(openssl rand -hex 16)"
    printf '%s\n' "$AURUM_POSTGRES_PASSWORD" > /data/.aurum-postgres-password
    chmod 600 /data/.aurum-postgres-password
  fi
  export AURUM_POSTGRES_PASSWORD
  log "postgres_password was left blank - generated one and stored it in /data/.aurum-postgres-password."
fi

export PGPASSWORD="$AURUM_POSTGRES_PASSWORD"

# The add-on's web port is published on the LAN by default, so a missing
# basic auth means anyone on the network can read every transaction. Surface
# it loudly instead of silently running with no password.
if [ -z "$AURUM_BASIC_AUTH_USER" ] || [ -z "$AURUM_BASIC_AUTH_PASSWORD" ]; then
  warn "AURUM_BASIC_AUTH_USER / AURUM_BASIC_AUTH_PASSWORD are not set."
  warn "Aurum is reachable at port 8099 with NO password. Set both options to"
  warn "enable HTTP Basic Auth in front of the whole app (UI and API)."
fi

# --- 2. PostgreSQL ----------------------------------------------------------

init_postgres() {
  # GNU install -d re-applies its default 0755 mode to an existing directory,
  # which Postgres rejects for its data dir (needs 0700 or 0750). Pin 0700 so
  # every boot re-establishes exactly what Postgres expects.
  install -d -m 0700 -o postgres -g postgres "$PG_DATA"
  chown -R postgres:postgres "$PG_DATA"

  if [ ! -s "$PG_DATA/PG_VERSION" ]; then
    log "Initialising Postgres data directory at ${PG_DATA}..."
    local pwfile
    pwfile="$(mktemp)"
    printf '%s\n' "$AURUM_POSTGRES_PASSWORD" > "$pwfile"
    chown postgres:postgres "$pwfile"
    runuser -u postgres -- initdb \
        --pgdata="$PG_DATA" \
        --username="$AURUM_POSTGRES_USER" \
        --pwfile="$pwfile" \
        --auth-host=password \
        --auth-local=trust
    rm -f "$pwfile"
  fi

  log "Starting Postgres..."
  runuser -u postgres -- pg_ctl \
      -D "$PG_DATA" \
      -o "-c listen_addresses=127.0.0.1 -c port=5432" \
      -l "$PG_DATA/postgres.log" \
      start >/dev/null

  local ready=0
  for _ in $(seq 1 30); do
    if runuser -u postgres -- pg_isready -q -h 127.0.0.1 -p 5432 -U "$AURUM_POSTGRES_USER"; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    warn "Postgres did not become ready in time; continuing anyway."
  fi
  log "Postgres is ready."

  # Whatever the data dir was created with, line the role's password up with
  # the current option on every boot. auth-local=trust lets us in over the
  # unix socket as the superuser (initdb created the role from --username,
  # i.e. "aurum" — not the default "postgres"), so a password set in the
  # options after the first start still takes effect. Single quotes are
  # doubled first so any password/name from the options is safe in SQL.
  local pw_sql user_sql db_sql
  pw_sql="${AURUM_POSTGRES_PASSWORD//\'/\'\'}"
  user_sql="${AURUM_POSTGRES_USER//\'/\'\'}"
  db_sql="${AURUM_POSTGRES_DB//\'/\'\'}"
  runuser -u postgres -- psql -U "$AURUM_POSTGRES_USER" -d postgres \
      -c "ALTER USER \"${user_sql}\" PASSWORD '${pw_sql}'" >/dev/null

  # Make sure the configured database actually exists.
  local exists
  exists="$(runuser -u postgres -- psql -U "$AURUM_POSTGRES_USER" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${db_sql}'" || true)"
  if [ "${exists}" != "1" ]; then
    runuser -u postgres -- createdb -U "$AURUM_POSTGRES_USER" \
        -O "$AURUM_POSTGRES_USER" "$AURUM_POSTGRES_DB"
    log "Created database '${AURUM_POSTGRES_DB}'."
  fi
}

# --- 3. Backend -------------------------------------------------------------

start_backend() {
  log "Applying database migrations (alembic upgrade head)..."
  runuser -u aurum -- bash -c "cd '${APPDIR}' && alembic upgrade head"

  log "Starting the Aurum backend on 127.0.0.1:8000..."
  runuser -u aurum -- uvicorn \
      --app-dir "$APPDIR" \
      app.main:app \
      --host 127.0.0.1 \
      --port 8000 &
  BACKEND_PID=$!
}

wait_for_backend() {
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  warn "The backend did not become healthy within 60s."
}

# --- 4/5. nginx -------------------------------------------------------------

start_nginx() {
  sh /usr/local/sbin/aurum-basic-auth.sh
  sh /usr/local/sbin/aurum-allowed-hosts.sh
  log "Starting nginx on port 8099..."
  nginx -g "daemon off;" &
  NGINX_PID=$!
}

# --- Lifecycle --------------------------------------------------------------

BACKEND_PID=
NGINX_PID=

shutdown() {
  log "Shutting down..."
  set +e
  if [ -n "$NGINX_PID" ]; then
    nginx -s quit >/dev/null 2>&1
    wait "$NGINX_PID" >/dev/null 2>&1
  fi
  if [ -n "$BACKEND_PID" ]; then
    pkill -TERM -u aurum -f 'uvicorn' >/dev/null 2>&1
  fi
  runuser -u postgres -- pg_ctl -D "$PG_DATA" -m fast stop >/dev/null 2>&1
  exit 0
}

trap shutdown TERM INT

init_postgres
start_backend
wait_for_backend
start_nginx

log "Aurum is up. Open http://[host]:8099 or use the 'Open Web UI' button in Home Assistant."
log "Default currency: ${AURUM_DEFAULT_CURRENCY}. Very first run is automatic (no account to create)."

# Stay in the foreground. The moment any of the three services exits we take
# the whole add-on down so the Supervisor can restart it cleanly.
wait -n || true
shutdown