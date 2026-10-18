# syntax=docker/dockerfile:1
# Multi-stage build for the Timetrack backend (Swift/Vapor), linux/arm64 and linux/amd64.
# Build:  docker buildx build --platform linux/amd64,linux/arm64 .
# With the PWA: add --build-context pwa-src=../timetrack-pwa (see the pwa-src stage).

ARG SWIFT_VERSION=6.3
ARG NODE_VERSION=26.5.0

# Build context of the PWA (static SvelteKit app, separate repository). Default: empty, so a plain
# `docker build .` still works and /srv/pwa stays empty (development mounts deploy/pwa-static there).
# Image with the PWA:  docker build --build-context pwa-src=../timetrack-pwa --build-arg PWA_REVISION=<sha> .
FROM scratch AS pwa-src

# The static output is platform independent, so this stage always runs natively on the builder
# (no QEMU for multi-arch builds). Without a package.json in the context it produces an empty directory.
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS pwa-build
WORKDIR /src
# Build metadata the PWA embeds (build/version.json and the Hilfe page, ADR-0023). The checkout has no .git, so the
# revision comes from here; PWA_VERSION falls back to package.json, BUILD_DATE to the build time.
ARG PWA_VERSION=""
ARG PWA_REVISION=""
ARG BUILD_DATE=""
ENV PWA_VERSION=${PWA_VERSION} PWA_REVISION=${PWA_REVISION} PWA_BUILD_DATE=${BUILD_DATE}
# The PWA repository has no .dockerignore: copy everything except dependencies and build output, so a local
# checkout with node_modules / .svelte-kit / build is neither read nor overwritten.
RUN --mount=type=bind,from=pwa-src,source=.,target=/ctx \
    tar -C /ctx --exclude=./node_modules --exclude=./.git --exclude=./.svelte-kit --exclude=./build \
        --exclude=./test-results -cf - . | tar -C /src -xf - \
    && if [ -f package.json ]; then npm ci && npm run build; else mkdir -p build; fi

# Dependency resolution only fetches git sources (architecture independent). It runs on the
# native builder platform because `swift package resolve` crashes under QEMU emulation
# (Illegal instruction) when the target platform differs from the host.
FROM --platform=$BUILDPLATFORM swift:${SWIFT_VERSION}-noble AS deps
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

FROM swift:${SWIFT_VERSION}-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
COPY --from=deps /build/.build /build/.build

COPY Sources ./Sources
# Tests/ must exist: SwiftPM validates declared test targets even when only building --product App.
COPY Tests ./Tests
# SwiftPM loads package manifests with massive thread parallelism, which crashes under QEMU user-mode
# emulation (SIGILL, amd64 build on an arm64 host). QEMU_LIMIT=1 pins manifest loading and the build to
# few CPUs and one job; native builds (default QEMU_LIMIT=0) use all CPUs. Example for emulated amd64:
#   docker buildx build --platform linux/amd64 --build-arg QEMU_LIMIT=1 ...
ARG QEMU_LIMIT=0
RUN if [ "$QEMU_LIMIT" = "1" ]; then taskset -c 0 swift package describe > /dev/null; fi

RUN if [ "$QEMU_LIMIT" = "1" ]; then LIMIT="taskset -c 0-1"; JOBS="-j 2"; else LIMIT=""; JOBS=""; fi; \
    $LIMIT swift build -c release --product App $JOBS \
    && mkdir -p /staging \
    && cp "$(swift build -c release --show-bin-path)/App" /staging/App \
    && (find "$(swift build -c release --show-bin-path)" -maxdepth 1 -name '*.resources' -exec cp -R {} /staging/ \;)

FROM swift:${SWIFT_VERSION}-noble-slim AS runtime
# Revision of the PWA checkout built into /srv/pwa (empty when built without the pwa-src context).
ARG PWA_REVISION=""
# Build metadata of the backend image (ADR-0023): shown by GET /api/v1/system/info and GET /health, and as OCI labels.
# Local builds without the arguments report "dev" / "unknown".
ARG APP_VERSION="dev"
ARG GIT_SHA="unknown"
ARG BUILD_DATE=""
LABEL org.opencontainers.image.pwa.revision="${PWA_REVISION}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}"
ENV TIMETRACK_VERSION=${APP_VERSION} TIMETRACK_REVISION=${GIT_SHA} TIMETRACK_BUILD_DATE=${BUILD_DATE}
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 tzdata curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 timetrack \
    && useradd --system --uid 10001 --gid timetrack --home-dir /app --shell /usr/sbin/nologin timetrack \
    && mkdir -p /app /data /srv/pwa \
    && chown -R timetrack:timetrack /app /data

WORKDIR /app
COPY --from=build --chown=timetrack:timetrack /staging/ /app/
# Built PWA (static files, no Node at runtime), served by the backend (PWA_STATIC_DIR).
COPY --from=pwa-build --chown=timetrack:timetrack /src/build /srv/pwa
# Translates VAR_FILE (Docker/Swarm secrets) into VAR, then execs /app/App (scripts/docker-entrypoint.sh).
COPY --chown=timetrack:timetrack --chmod=0755 scripts/docker-entrypoint.sh /app/docker-entrypoint.sh

USER timetrack:timetrack
ENV HOST=0.0.0.0 PORT=8080 SQLITE_PATH=/data/timetrack.sqlite PWA_STATIC_DIR=/srv/pwa
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
