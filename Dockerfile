# syntax=docker/dockerfile:1
# Multi-stage build for the Timetrack backend (Swift/Vapor), linux/arm64 and linux/amd64.
# Build:  docker buildx build --platform linux/amd64,linux/arm64 .

ARG SWIFT_VERSION=6.3

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
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 tzdata curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 timetrack \
    && useradd --system --uid 10001 --gid timetrack --home-dir /app --shell /usr/sbin/nologin timetrack \
    && mkdir -p /app /data /srv/pwa \
    && chown -R timetrack:timetrack /app /data

WORKDIR /app
COPY --from=build --chown=timetrack:timetrack /staging/ /app/
# Translates VAR_FILE (Docker/Swarm secrets) into VAR, then execs /app/App (scripts/docker-entrypoint.sh).
COPY --chown=timetrack:timetrack --chmod=0755 scripts/docker-entrypoint.sh /app/docker-entrypoint.sh

USER timetrack:timetrack
ENV HOST=0.0.0.0 PORT=8080 SQLITE_PATH=/data/timetrack.sqlite
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
