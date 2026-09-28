ARG CADDY_BUILDER_IMAGE
ARG CADDY_RUNTIME_IMAGE

FROM ${CADDY_BUILDER_IMAGE} AS builder
ARG CADDY_VERSION=2.11.4

RUN CGO_ENABLED=0 xcaddy build v${CADDY_VERSION} \
    --with github.com/caddy-dns/cloudflare@v0.2.4

FROM ${CADDY_RUNTIME_IMAGE}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN caddy list-modules | grep -Fx dns.providers.cloudflare
