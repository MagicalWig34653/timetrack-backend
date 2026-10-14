#!/usr/bin/env bash
# Helper for the local Timetrack container environment (compose project timetrack-dev).
# Only touches resources of this project. Never prunes, never removes volumes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PROJECT=timetrack-dev
DC=(docker compose --project-name "$PROJECT" -f "$ROOT/compose.yaml")
PROFILES=(--profile app --profile sqlite --profile mail --profile s3 --profile oidc)

usage() {
  cat <<USAGE
Usage: scripts/dev-env.sh <command>
  init             create .env with random dev passwords if missing
  up               start the MariaDB container (waits until healthy)
  up-app           build and start db + backend (profile app)
  up-sqlite        build and start backend in SQLite single-instance mode (profile sqlite)
  up-mail          start Mailpit (profile mail)
  up-s3            start Adobe S3Mock (profile s3)
  up-oidc          start Dex OIDC test provider (profile oidc)
  s3-env           print S3 settings for the admin storage form
  down             stop the project containers (volumes are kept)
  logs [service]   follow logs
  db-shell         open the mariadb client inside the db container
  status           show containers, ports and volumes of the project
  build-multiarch  buildx build for linux/amd64 and linux/arm64 (no push)
  test-db          wait for healthy db and print export lines for MariaDB tests
USAGE
}

env_get() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28; }

need_env() { [ -f .env ] || { echo ".env missing: run scripts/dev-env.sh init" >&2; exit 1; }; }

wait_healthy() {
  local cid status i
  cid="$("${DC[@]}" ps -q db)"
  [ -n "$cid" ] || { echo "db container not running" >&2; exit 1; }
  for i in $(seq 1 90); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$cid")"
    [ "$status" = healthy ] && { echo "db healthy"; return 0; }
    sleep 2
  done
  echo "db not healthy after 180s" >&2; exit 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init)
    if [ -f .env ]; then echo ".env exists, left untouched"; exit 0; fi
    sed -e "s/^DB_ROOT_PASSWORD=.*/DB_ROOT_PASSWORD=$(rand)/" \
        -e "s/^DB_PASSWORD=.*/DB_PASSWORD=$(rand)/" .env.example > .env
    chmod 600 .env
    echo ".env created with generated passwords"
    ;;
  up)
    need_env; "${DC[@]}" up -d db; wait_healthy ;;
  up-app)
    need_env; "${DC[@]}" --profile app up -d --build backend; wait_healthy ;;
  up-sqlite)
    need_env; "${DC[@]}" --profile sqlite up -d --build backend-sqlite ;;
  up-mail)
    need_env; "${DC[@]}" --profile mail up -d mailpit ;;
  up-s3)
    need_env; "${DC[@]}" --profile s3 up -d s3mock ;;
  up-oidc)
    need_env; "${DC[@]}" --profile oidc up -d dex ;;
  s3-env)
    need_env
    cat <<S3ENV
endpoint:    http://127.0.0.1:$(env_get S3_HTTP_HOST_PORT)
region:      us-east-1
bucket:      $(env_get S3_BUCKET)
path-style:  true
access key:  dummy-access-key   (S3Mock accepts any credentials)
secret key:  dummy-secret-key
S3ENV
    ;;
  down)
    need_env; "${DC[@]}" "${PROFILES[@]}" down ;;  # no -v on purpose
  logs)
    need_env; "${DC[@]}" "${PROFILES[@]}" logs -f "$@" ;;
  db-shell)
    need_env
    "${DC[@]}" exec db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' ;;
  status)
    need_env
    "${DC[@]}" "${PROFILES[@]}" ps -a
    docker volume ls --filter name=timetrack-dev ;;
  build-multiarch)
    # Multi-platform results cannot be loaded into the local daemon; write OCI archive to a tmp dir.
    out="$(mktemp -d)"
    # QEMU_LIMIT=1 keeps SwiftPM stable under emulation (needed on an arm64 host for amd64; harmless otherwise).
    docker buildx build --platform linux/amd64,linux/arm64 --build-arg QEMU_LIMIT="${QEMU_LIMIT:-1}" \
      --output "type=oci,dest=$out/timetrack-backend.oci.tar" -t timetrack-dev-backend:multiarch .
    echo "OCI archive: $out/timetrack-backend.oci.tar (not pushed)" ;;
  test-db)
    need_env; wait_healthy
    cat <<EXPORTS
export MARIADB_TEST_HOST=127.0.0.1
export MARIADB_TEST_PORT=$(env_get DB_HOST_PORT)
export MARIADB_TEST_USER=root
export MARIADB_TEST_PASSWORD=$(env_get DB_ROOT_PASSWORD)
# Tests create/drop their own throwaway databases, hence the root user.
EXPORTS
    ;;
  *) usage; exit 1 ;;
esac
