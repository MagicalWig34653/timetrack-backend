#!/usr/bin/env bash
# Smoke test of the production-shaped container (deploy/swarm/stack.yaml): *_FILE secrets via
# scripts/docker-entrypoint.sh, read-only root filesystem, one-shot migrate command, /health and /ready,
# AASA pass-through. Uses the dev Compose MariaDB with the throwaway database timetrack_smoke_test, a container
# named timetrack-dev-b3-smoke and host port >= 18150. Does not use Swarm.
# Usage: scripts/test-image-smoke.sh [IMAGE]    (default timetrack-dev-b3-backend:test; build it: docker build -t timetrack-dev-b3-backend:test .)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/backup-common.sh
. "$ROOT/scripts/lib/backup-common.sh"

IMAGE="${1:-timetrack-dev-b3-backend:test}"
TT_DB_CONTAINER="${TT_DB_CONTAINER:-timetrack-dev-db-1}"
NETWORK="${TT_DEV_NETWORK:-timetrack-dev_default}"
PORT="${TEST_SMOKE_PORT:-18152}"
NAME=timetrack-dev-b3-smoke
DB=timetrack_smoke_test
[ "$PORT" -ge 18150 ] || tt_die "port must be >= 18150"
case "$IMAGE" in timetrack-dev-*) ;; *) tt_die "image must be named timetrack-dev-*" ;; esac

# Colima shares only the home directory with the VM; bind-mount sources in /var/folders would show up as empty directories.
mkdir -p "${SMOKE_TMP:-$HOME/.cache}"
SECRETS="$(mktemp -d "${SMOKE_TMP:-$HOME/.cache}/timetrack-smoke.XXXXXX")"
PASS=0; FAILED=0; RESULTS=()
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); RESULTS+=("PASS  $what"); else FAILED=$((FAILED + 1)); RESULTS+=("FAIL  $what"); fi; }
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  tt_mysql_q "DROP DATABASE IF EXISTS \`$DB\`" >/dev/null 2>&1 || true
  if [ -n "$SECRETS" ] && [ -d "$SECRETS" ]; then rm -rf "$SECRETS"; fi
}
trap cleanup EXIT

umask 077
docker exec "$TT_DB_CONTAINER" printenv MARIADB_ROOT_PASSWORD >"$SECRETS/db"
openssl rand -base64 32 >"$SECRETS/storage"
openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER 2>/dev/null | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n' >"$SECRETS/vapid"
chmod 644 "$SECRETS"/*   # like Swarm secrets (0444 in /run/secrets); the directory is a private temp dir
tt_mysql_q "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"

common=(--network "$NETWORK" --read-only --tmpfs /tmp
  -v "$SECRETS/db:/run/secrets/tt_db_password:ro" -v "$SECRETS/storage:/run/secrets/tt_storage_secret_key:ro" -v "$SECRETS/vapid:/run/secrets/tt_vapid_private_key:ro"
  -e DATABASE_DRIVER=mariadb -e DB_HOST=db -e DB_NAME="$DB" -e DB_USER=root -e DB_TLS=off -e AUTO_MIGRATE=false)

tt_log "migrate job (first run, empty database)"
docker run --rm --name "$NAME-migrate" "${common[@]}" -e DB_PASSWORD_FILE=/run/secrets/tt_db_password "$IMAGE" migrate --yes --env production >/dev/null 2>&1 || true
N1="$(tt_mysql_q 'SELECT COUNT(*) FROM _fluent_migrations' "$DB" 2>/dev/null || echo 0)"
check "migrate job applied migrations through DB_PASSWORD_FILE (rows in _fluent_migrations: $N1)" test "$N1" -gt 0
docker run --rm --name "$NAME-migrate" "${common[@]}" -e DB_PASSWORD_FILE=/run/secrets/tt_db_password "$IMAGE" migrate --yes --env production >/dev/null 2>&1 || true
check "second migrate run is a no-op" test "$(tt_mysql_q 'SELECT COUNT(*) FROM _fluent_migrations' "$DB")" = "$N1"
RC=0; docker run --rm "${common[@]}" -e DB_PASSWORD_FILE=/run/secrets/tt_db_password -e DB_PASSWORD=x "$IMAGE" migrate --yes >/dev/null 2>&1 || RC=$?
check "entrypoint refuses VAR and VAR_FILE together (exit 64, got $RC)" test "$RC" = 64
RC=0; docker run --rm "${common[@]}" -e DB_PASSWORD_FILE=/run/secrets/nonexistent "$IMAGE" migrate --yes >/dev/null 2>&1 || RC=$?
check "entrypoint fails on an unreadable secret file (exit 66, got $RC)" test "$RC" = 66

tt_log "serve (read-only root, secrets from files)"
docker run -d --name "$NAME" "${common[@]}" -p "127.0.0.1:$PORT:8080" \
  -e DB_PASSWORD_FILE=/run/secrets/tt_db_password -e STORAGE_SECRET_KEY_FILE=/run/secrets/tt_storage_secret_key \
  -e VAPID_PRIVATE_KEY_FILE=/run/secrets/tt_vapid_private_key -e VAPID_SUBJECT=mailto:admin@example.test \
  -e PUBLIC_BASE_URL="http://localhost:$PORT" -e WEBAUTHN_ORIGIN="http://localhost:$PORT" -e APPLE_APP_IDS=ABCDE12345.de.example.timetrack \
  "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/ready")" = 200 ] && break
  sleep 1
done
check "/ready is 200 (database reachable, migrations applied)" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/ready")" = 200
check "/health is 200" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")" = 200
check "apple-app-site-association is served without redirect (200, JSON)" bash -c 'out="$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}|%{content_type}" "$1")"; [ "${out%%|*}" = "200 " ] && [[ "${out#*|}" == application/json* ]]' _ "http://127.0.0.1:$PORT/.well-known/apple-app-site-association"
env_len() { docker exec "$NAME" sh -c "tr '\\0' '\\n' </proc/1/environ | grep \"^$1=\" | cut -d= -f2- | tr -d '\\n' | wc -c" | tr -d ' '; }
file_len() { tr -d '\n' <"$1" | wc -c | tr -d ' '; }
check "STORAGE_SECRET_KEY is in the process environment with the file's length" test "$(env_len STORAGE_SECRET_KEY)" = "$(file_len "$SECRETS/storage")"
check "VAPID_PRIVATE_KEY is in the process environment with the file's length" test "$(env_len VAPID_PRIVATE_KEY)" = "$(file_len "$SECRETS/vapid")"
check "DB_PASSWORD is in the process environment with the file's length" test "$(env_len DB_PASSWORD)" = "$(file_len "$SECRETS/db")"
check "the *_FILE variables are not left in the process environment" bash -c '! docker exec "$1" sh -c "tr \"\\0\" \"\\n\" </proc/1/environ | grep -q \"_FILE=\""' _ "$NAME"
check "docker healthcheck of the image reports healthy" bash -c 'for _ in $(seq 1 40); do [ "$(docker inspect -f "{{.State.Health.Status}}" "$1")" = healthy ] && exit 0; sleep 2; done; exit 1' _ "$NAME"
check "container runs as non-root uid 10001" test "$(docker exec "$NAME" id -u)" = 10001
check "no secret value in the container log" bash -c '! docker logs "$1" 2>&1 | grep -qF -e "$(cat "$2")" -e "$(cat "$3")"' _ "$NAME" "$SECRETS/storage" "$SECRETS/db"

printf '%s\n' "${RESULTS[@]}"
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
