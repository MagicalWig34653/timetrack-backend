#!/usr/bin/env bash
# CI smoke test of a built image: starts it with a throwaway SQLite database and waits for GET /health.
# EXPECT_PWA=1 additionally requires the built PWA: GET / and a deep link must return the HTML shell.
# Used by .github/workflows/docker.yml; also works locally:  scripts/ci-smoke.sh IMAGE [HOST_PORT]
set -euo pipefail

IMAGE="${1:?usage: scripts/ci-smoke.sh IMAGE [HOST_PORT]}"
PORT="${2:-18199}"
NAME="timetrack-ci-smoke-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:8080" \
  -e DATABASE_DRIVER=sqlite -e SQLITE_PATH=/data/timetrack.sqlite -e AUTO_MIGRATE=true \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if body="$(curl -fsS "http://127.0.0.1:${PORT}/health" 2>/dev/null)"; then
    echo "/health: $body"
    if [ "${EXPECT_PWA:-0}" = "1" ]; then
      for path in / /settings/profile; do
        page="$(curl -fsS "http://127.0.0.1:${PORT}${path}")" || { echo "GET $path failed" >&2; exit 1; }
        if ! grep -q '<html' <<< "$page"; then
          echo "GET $path did not return the PWA HTML shell" >&2; exit 1
        fi
        echo "GET $path: PWA HTML shell"
      done
    fi
    exit 0
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
    echo "container exited early" >&2; docker logs "$NAME" >&2; exit 1
  fi
  sleep 1
done
echo "no healthy answer within 60 s" >&2
docker logs "$NAME" >&2
exit 1
