# syntax=docker/dockerfile:1
# Multi-stage build for the Timetrack backend (Swift/Vapor), linux/arm64 and linux/amd64.
# Build:  docker buildx build --platform linux/amd64,linux/arm64 .

ARG SWIFT_VERSION=6.3

FROM swift:${SWIFT_VERSION}-noble AS build
WORKDIR /build

# Resolve dependencies first so this layer is cached while only sources change.
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
# Tests/ is optional (not needed for the release binary).
RUN swift build -c release --product App \
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

USER timetrack:timetrack
ENV HOST=0.0.0.0 PORT=8080 SQLITE_PATH=/data/timetrack.sqlite
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/app/App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
