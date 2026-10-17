#!/usr/bin/env bash
# CI smoke test of a built image: starts it with a throwaway SQLite database and waits for GET /health.
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
