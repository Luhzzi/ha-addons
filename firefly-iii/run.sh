#!/usr/bin/env bash
#
# Entrypoint for the Firefly III Home Assistant add-on.
#
# Firefly III upstream is two containers (fireflyiii/core + a database); this
# script turns it into one:
#
#   1. read the Supervisor options from /data/options.json and export the
#      DB_*/APP_* environment variables the app expects;
#   2. initialise the MariaDB data directory under /data (persistent) and
#      start the server bound to 127.0.0.1:3306;
#   3. create the Firefly database and user;
#   4. hand over to the official entrypoint, which on first start creates the
#      schema (php artisan firefly-iii:create-database / upgrade-database),
#      generates the nginx config (plain HTTP on 8080) and runs the app.
#
# A small background loop also pokes the app's own cron endpoint so recurring
# transactions, bills and budgets keep working without a separate cron
# container.

set -euo pipefail

readonly CONFIG_PATH=/data/options.json
readonly DB_DATA=/data/firefly-db
readonly DB_NAME=firefly
readonly DB_USER=firefly
readonly APP_DIR=/var/www/html

log() { echo "[firefly-iii] $*"; }

# --- 1. Options ------------------------------------------------------------

DB_PASSWORD="$(jq -r '.database_password // ""' "$CONFIG_PATH")"
APP_KEY="$(jq -r '.app_key // ""' "$CONFIG_PATH")"
APP_URL="$(jq -r '.app_url // ""' "$CONFIG_PATH")"
SITE_OWNER="$(jq -r '.site_owner // ""' "$CONFIG_PATH")"
TZ_VALUE="$(jq -r '.timezone // "Europe/Moscow"' "$CONFIG_PATH")"
DEFAULT_LANGUAGE="$(jq -r '.language // "ru_RU"' "$CONFIG_PATH")"
DEFAULT_LOCALE="$(jq -r '.locale // "ru_RU"' "$CONFIG_PATH")"

# Secrets that must stay stable across restarts are generated once and kept
# in /data (preserved by the Supervisor between runs and in backups).
if [ -z "$DB_PASSWORD" ]; then
  if [ -f /data/.firefly-db-password ]; then
    DB_PASSWORD="$(< /data/.firefly-db-password)"
  else
    DB_PASSWORD="$(openssl rand -hex 16)"
    printf '%s\n' "$DB_PASSWORD" > /data/.firefly-db-password
    chmod 600 /data/.firefly-db-password
    log "database_password was left blank - generated one and stored it in /data/.firefly-db-password."
  fi
fi
if [ -z "$APP_KEY" ]; then
  if [ -f /data/.firefly-app-key ]; then
    APP_KEY="$(< /data/.firefly-app-key)"
  else
    APP_KEY="$(openssl rand -hex 16)"
    printf '%s\n' "$APP_KEY" > /data/.firefly-app-key
    chmod 600 /data/.firefly-app-key
    log "app_key was left blank - generated one and stored it in /data/.firefly-app-key."
  fi
fi
CRON_TOKEN=""
if [ -f /data/.firefly-cron-token ]; then
  CRON_TOKEN="$(< /data/.firefly-cron-token)"
fi
if [ -z "$CRON_TOKEN" ]; then
  CRON_TOKEN="$(openssl rand -hex 16)"
  printf '%s\n' "$CRON_TOKEN" > /data/.firefly-cron-token
  chmod 600 /data/.firefly-cron-token
fi

export DB_CONNECTION=mysql \
       DB_HOST=127.0.0.1 \
       DB_PORT=3306 \
       DB_DATABASE="$DB_NAME" \
       DB_USERNAME="$DB_USER" \
       DB_PASSWORD \
       APP_ENV=production \
       APP_KEY \
       APP_URL="${APP_URL:-http://localhost}" \
       TRUSTED_PROXIES="**" \
       SITE_OWNER \
       DEFAULT_LANGUAGE \
       DEFAULT_LOCALE \
       STATIC_CRON_TOKEN="$CRON_TOKEN" \
       TZ="$TZ_VALUE"

# --- 2. MariaDB ------------------------------------------------------------

install -d -m 0755 /run/mysqld
chown mysql:mysql /run/mysqld

if [ ! -f "$DB_DATA/firefly-iii-db.initialised" ]; then
  mkdir -p "$DB_DATA"
  chown -R mysql:mysql "$DB_DATA"
  log "Initialising MariaDB data directory at ${DB_DATA}..."
  mariadb-install-db --user=mysql --datadir="$DB_DATA"
  touch "$DB_DATA/firefly-iii-db.initialised"
else
  chown -R mysql:mysql "$DB_DATA"
fi

log "Starting MariaDB on 127.0.0.1:3306..."
mariadbd \
  --user=mysql \
  --datadir="$DB_DATA" \
  --socket=/run/mysqld/mysqld.sock \
  --pid-file=/run/mysqld/mysqld.pid \
  --bind-address=127.0.0.1 \
  --port=3306 &
DB_PID=$!
trap 'kill "$DB_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 60); do
  if mariadb-admin --socket=/run/mysqld/mysqld.sock ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  log "ERROR: MariaDB did not become ready in time."
  exit 1
fi

# Create the database and app user (Firefly's own create-database step will
# then find both already present). Single quotes in the password are doubled
# so any value from the options is safe in SQL.
pw_sql="${DB_PASSWORD//\'/\'\'}"
db_sql="${DB_NAME//\'/\'\'}"
mariadb --socket=/run/mysqld/mysqld.sock -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_sql}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${pw_sql}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${pw_sql}';
GRANT ALL PRIVILEGES ON \`${db_sql}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${db_sql}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
log "MariaDB is up; database '${DB_NAME}' and user '${DB_USER}' are ready."

# --- 3. Persistent uploads -------------------------------------------------

mkdir -p /data/firefly-upload
chown www-data:www-data /data/firefly-upload
ln -sfn /data/firefly-upload "${APP_DIR}/storage/upload"

# --- 4. Internal cron loop (recurring transactions, bills, budgets) --------

(
  while :; do
    curl -fsS "http://127.0.0.1:8080/api/v1/cron/${CRON_TOKEN}?force=true" >/dev/null 2>&1 || true
    sleep 300
  done
) &

# --- 5. Official startup ----------------------------------------------------
#
# Hand over to the stock entrypoint: it runs the config generation, creates/
# upgrades the database schema and starts nginx (8080) + php-fpm via s6.

log "Handing over to the official Firefly III startup..."
exec /usr/local/bin/docker-php-serversideup-entrypoint /init