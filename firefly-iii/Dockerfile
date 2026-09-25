# syntax=docker/dockerfile:1
#
# Firefly III — Home Assistant add-on (single container).
#
# The official fireflyiii/core image already runs the whole app: nginx on
# 8080 (plain HTTP, SSL_MODE defaults to "off"), php-fpm, and on first start
# it creates the database and runs all migrations itself. The only thing it
# needs from outside is a reachable database, so this add-on simply adds
# MariaDB into the same container, sets the DB_*/APP_* environment, and then
# hands control over to the official entrypoint (which also generates the
# nginx config and serves the app). No custom web server, no extra auth —
# Firefly III has its own register/login/2FA.

ARG BUILD_VERSION=0.1.0
ARG FF_REF=version-6.7.4

FROM fireflyiii/core:${FF_REF}

USER root

# mariadb: the bundled database (upstream runs it in a second container).
# mariadb-client/server packages bring mariadbd, mariadb-install-db and the
# CLI tools used by run.sh to create the app user/database. jq/openssl/curl/
# tzdata parse /data/options.json, generate secrets, run the internal cron
# loop and provide the configured timezone to PHP.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        jq \
        openssl \
        curl \
        tzdata && \
    rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod a+x /run.sh

LABEL \
    io.hass.name="Firefly III" \
    io.hass.description="Open source personal finance manager" \
    io.hass.type="app" \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.arch="aarch64|amd64"

EXPOSE 8080

ENTRYPOINT []
CMD ["/run.sh"]