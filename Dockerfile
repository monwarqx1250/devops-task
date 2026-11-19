# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Bun/Fastify service.
#   - Base image pinned by version and multi-arch digest (amd64 + arm64)
#   - Production dependencies installed from bun.lock (reproducible)
#   - Final image runs as the non-root "bun" user (uid 1000)

# ---- dependencies: install production node_modules only ----------------------
FROM oven/bun:1.3.8-alpine@sha256:b0885548002187f088af5c7e04008f852c0a30cbe4192b5d75c3266a7f0b01f5 AS dependencies
WORKDIR /app
COPY package.json bun.lock ./
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --frozen-lockfile --production --ignore-scripts

# ---- runtime: app source + production dependencies ----------------------------
FROM oven/bun:1.3.8-alpine@sha256:b0885548002187f088af5c7e04008f852c0a30cbe4192b5d75c3266a7f0b01f5 AS runtime

ARG VERSION=1.0.0
ARG REVISION=unknown
ARG CREATED=unknown
ARG SOURCE=https://github.com/monwarqx1250/devops-task

LABEL org.opencontainers.image.title="devops-task-service" \
      org.opencontainers.image.description="Fastify service with health checks and Prometheus metrics" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/oven/bun:1.3.8-alpine"

ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${VERSION}

# Patch OS packages with known fixes that the pinned base image predates
# (e.g. CVE-2026-31789 in OpenSSL). Trivy in CI fails on CRITICAL CVEs with a fix.
RUN apk upgrade --no-cache libcrypto3 libssl3

WORKDIR /app
COPY --from=dependencies --chown=bun:bun /app/node_modules ./node_modules
COPY --chown=bun:bun package.json server.ts ./
COPY --chown=bun:bun src ./src

USER bun
EXPOSE 3000
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:3000/health || exit 1

CMD ["bun", "server.ts"]
