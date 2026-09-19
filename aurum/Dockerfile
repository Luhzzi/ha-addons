# syntax=docker/dockerfile:1
#
# Aurum — Home Assistant add-on.
#
# Aurum upstream ships as three containers (Postgres, FastAPI backend and an
# nginx-served React SPA) wired together with Docker Compose. A Home
# Assistant add-on is a single image, so this Dockerfile merges all three
# roles into one container:
#
#   - the SPA is built in the `frontend` stage, exactly like
#     frontend/Dockerfile upstream (npm ci + npm run build);
#   - the backend's Python dependencies are installed into a venv in the
#     `backend` stage, so the runtime image needs no build toolchain;
#   - the `runtime` stage adds PostgreSQL (as shipped by the base image's
#     Debian) and nginx, and runs everything from /run.sh (see config.yaml:
#     init: false, so the add-on's own entrypoint is used instead of s6).
#
# The application source is pulled from the Aurum upstream repository at
# build time. Set AURUM_REF to a commit/tag to pin a specific upstream
# version instead of following main.

ARG BUILD_VERSION=0.1.0
ARG AURUM_REF=main

# --------------------------------------------------------------- frontend
FROM node:22-alpine AS frontend

ARG AURUM_REF
RUN apk add --no-cache ca-certificates

WORKDIR /src
RUN wget -qO aurum.tar.gz "https://github.com/Zproger/Aurum/archive/refs/heads/${AURUM_REF}.tar.gz"
RUN tar -xzf aurum.tar.gz --strip-components=1 && rm aurum.tar.gz

WORKDIR /src/frontend
RUN npm ci
RUN npm run build

# ---------------------------------------------------------------- backend
FROM python:3.12-slim AS backend

ARG AURUM_REF
ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL -o aurum.tar.gz "https://github.com/Zproger/Aurum/archive/refs/heads/${AURUM_REF}.tar.gz"
RUN tar -xzf aurum.tar.gz --strip-components=1 && rm aurum.tar.gz

RUN python3 -m venv /opt/aurum/venv \
    && /opt/aurum/venv/bin/pip install --upgrade pip \
    && /opt/aurum/venv/bin/pip install -r /src/backend/requirements.txt

# ---------------------------------------------------------------- runtime
FROM python:3.12-slim AS runtime

ARG BUILD_VERSION

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    PATH="/opt/aurum/venv/bin:${PATH}"

# postgresql provides the database, nginx the published web entry point.
# jq parses /data/options.json in run.sh; openssl generates the basic-auth
# htpasswd hash and falls back to generating the database password.
# (runuser comes from util-linux, which is already installed in the base.)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql \
        nginx \
        openssl \
        curl \
        jq \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/share/nginx/html/*.html \
    && useradd --create-home --uid 10001 aurum

COPY --from=backend /opt/aurum/venv /opt/aurum/venv
COPY --from=backend /src/backend /opt/aurum/backend
COPY --from=frontend /src/frontend/dist /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/aurum.conf
COPY 20-basic-auth.sh /usr/local/sbin/aurum-basic-auth.sh
COPY 25-allowed-hosts.sh /usr/local/sbin/aurum-allowed-hosts.sh
COPY run.sh /run.sh

RUN chmod a+x /run.sh /usr/local/sbin/aurum-basic-auth.sh /usr/local/sbin/aurum-allowed-hosts.sh \
    && rm -f /etc/nginx/sites-enabled/default \
    && touch /etc/nginx/basic-auth.conf /etc/nginx/allowed-hosts.conf

LABEL \
    io.hass.name="Aurum" \
    io.hass.description="Self-hosted personal finance OS" \
    io.hass.type="app" \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.arch="aarch64|amd64"

EXPOSE 8099

CMD ["/run.sh"]