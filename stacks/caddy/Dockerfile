# Compose cannot lock FROM images, so keep these base digests pinned here.
FROM docker.io/library/caddy:2.11.4-builder@sha256:369218c81ca6d6af249981221b3a5c764d886dd5b058f51d144066de13f2418d AS builder
ARG CADDY_VERSION=2.11.4

RUN CGO_ENABLED=0 xcaddy build v${CADDY_VERSION} \
    --with github.com/caddy-dns/cloudflare@v0.2.4
