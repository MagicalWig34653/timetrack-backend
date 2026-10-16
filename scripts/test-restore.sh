#!/usr/bin/env bash
# End-to-end proof of scripts/backup.sh + scripts/restore.sh on SQLite and on the dev Compose MariaDB.
# For each driver: start a throwaway backend, create synthetic data through the real backend (CLI + REST API),
# back up while the backend runs, wipe everything, restore, start the backend again and verify counts, file
# hashes and that stored files are readable through the API. Also checks the refusal paths.
#
# Touches only: throwaway database timetrack_restore_test in the container timetrack-dev-db-1, S3Mock bucket
# objects it creates itself (deleted again), temp directories, backend processes on ports >= 18150.
# Usage: scripts/test-restore.sh [sqlite|mariadb|all]      (needs .build/debug/App, built with `swift build --build-system native --product App`)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/backup-common.sh
. "$ROOT/scripts/lib/backup-common.sh"

APP="${APP:-$ROOT/.build/debug/App}"
TT_DB_CONTAINER="${TT_DB_CONTAINER:-timetrack-dev-db-1}"
TEST_DB="timetrack_restore_test"
PORT_SQLITE="${TEST_PORT_SQLITE:-18150}"
PORT_MARIADB="${TEST_PORT_MARIADB:-18151}"
S3_ENDPOINT="${TEST_S3_ENDPOINT:-http://127.0.0.1:19090}"
S3_BUCKET="${TEST_S3_BUCKET:-timetrack-dev}"
CASES="${1:-all}"
[ "$PORT_SQLITE" -ge 18150 ] && [ "$PORT_MARIADB" -ge 18150 ] || tt_die "ports must be >= 18150 (18080 is the live instance)"
[ -x "$APP" ] || tt_die "backend binary not found: $APP (swift build --build-system native --product App)"
command -v sqlite3 >/dev/null && command -v curl >/dev/null && command -v openssl >/dev/null || tt_die "sqlite3, curl and openssl are required"

WORK="$(mktemp -d)"
SERVER_PID=""
PASS=0
FAILED=0
RESULTS=()

cleanup() {
  stop_backend
  if docker inspect "$TT_DB_CONTAINER" >/dev/null 2>&1; then
    tt_mysql_q "DROP DATABASE IF EXISTS \`$TEST_DB\`" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

check() { # check "description" command...
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); RESULTS+=("PASS  $what")
  else FAILED=$((FAILED + 1)); RESULTS+=("FAIL  $what"); tt_log "FAILED: $what"; fi
}
check_fail() { # expects the command to fail
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then FAILED=$((FAILED + 1)); RESULTS+=("FAIL  $what"); tt_log "FAILED (expected refusal): $what"
  else PASS=$((PASS + 1)); RESULTS+=("PASS  $what"); fi
}

# --- backend process and HTTP helpers -----------------------------------------------------------------------------
stop_backend() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; fi
}

# Environment of the throwaway backend (secrets exist only in this process environment).
backend_env() { # backend_env driver port sqlite_path storage_key migrate
  local driver="$1" port="$2" sqlite="$3" key="$4" migrate="$5"
  local -a e=(DATABASE_DRIVER="$driver" AUTO_MIGRATE="$migrate" PUBLIC_BASE_URL="http://localhost:$port"
    WEBAUTHN_ORIGIN="http://localhost:$port" WEBAUTHN_RP_ID=localhost PWA_STATIC_DIR="$WORK" STORAGE_SECRET_KEY="$key"
    NOTIFICATIONS_ENABLED=false SQLITE_PATH="$sqlite")
  if [ "$driver" = mariadb ]; then
    e+=(DB_HOST=127.0.0.1 DB_PORT="$MARIADB_HOST_PORT" DB_NAME="$TEST_DB" DB_USER=root DB_PASSWORD="$MARIADB_ROOT_PW" DB_TLS=off)
  fi
  printf '%s\n' "${e[@]}"
}

start_backend() { # start_backend driver port sqlite_path storage_key migrate
  local port="$2"
  local -a envs
  while IFS= read -r line; do envs+=("$line"); done < <(backend_env "$@")
  env "${envs[@]}" "$APP" serve --env production --hostname 127.0.0.1 --port "$port" >"$WORK/backend-$port.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/ready")" = 200 ]; then return 0; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { tail -5 "$WORK/backend-$port.log" >&2; tt_die "backend exited during start"; }
    sleep 1
  done
  tail -5 "$WORK/backend-$port.log" >&2; tt_die "backend not ready after 60s"
}

# Session of the synthetic admin (token is random per run; only its hash is stored in the database).
b64url_sha256() { printf %s "$1" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
TOKEN=""; CSRF=""
api() { # api METHOD path [json]  -> body on stdout, fails on HTTP >= 400
  local method="$1" path="$2" body="${3:-}" out code
  out="$WORK/api.out"
  if [ -n "$body" ]; then
    code="$(curl -s -o "$out" -w '%{http_code}' -X "$method" -b "tt_session=$TOKEN" -H "X-CSRF-Token: $CSRF" -H 'content-type: application/json' -d "$body" "http://127.0.0.1:$PORT$path")"
  else
    code="$(curl -s -o "$out" -w '%{http_code}' -X "$method" -b "tt_session=$TOKEN" -H "X-CSRF-Token: $CSRF" "http://127.0.0.1:$PORT$path")"
  fi
  cat "$out"
  [ "$code" -lt 400 ] || { tt_log "HTTP $code for $method $path: $(head -c 200 "$out")"; return 1; }
}
upload() { # upload FILE -> file id
  local out="$WORK/upload.out" code
  code="$(curl -s -o "$out" -w '%{http_code}' -b "tt_session=$TOKEN" -H "X-CSRF-Token: $CSRF" -F "file=@$1;type=application/pdf" "http://127.0.0.1:$PORT/api/v1/files")"
  [ "$code" = 201 ] || { tt_log "upload failed: HTTP $code $(head -c 200 "$out")"; return 1; }
  sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$out"
}
download_sha() { # download_sha ID -> sha256 of the bytes served by the API ("ERR<code>" on failure)
  local code
  code="$(curl -s -o "$WORK/dl.bin" -w '%{http_code}' -b "tt_session=$TOKEN" "http://127.0.0.1:$PORT/api/v1/files/$1")"
  if [ "$code" = 200 ]; then tt_sha256 "$WORK/dl.bin"; else echo "ERR$code"; fi
}
synthetic_pdf() { # synthetic_pdf FILE BYTES
  { printf '%%PDF-1.4\n'; head -c "$(( $2 - 16 ))" /dev/urandom; printf '\n%%%%EOF\n'; } >"$1"
}

seed_account() { # seed_account driver  (account and session rows; there is no passkey-free login by design)
  local driver="$1" acct="aaaaaaaa-0000-4000-8000-000000000001" sess="aaaaaaaa-0000-4000-8000-0000000000a1"
  TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
  CSRF="$(b64url_sha256 "timetrack.csrf.v1:$TOKEN")"
  local th csh; th="$(b64url_sha256 "$TOKEN")"; csh="$(b64url_sha256 "$CSRF")"
  if [ "$driver" = sqlite ]; then
    sqlite3 "$SQLITE_FILE" "INSERT INTO accounts(id,handle,display_name,role,created_at) VALUES(upper('$acct'),'synth-admin','Synthetic Admin','admin',strftime('%s','now'));
      INSERT INTO sessions(id,account_id,token_hash,csrf_token_hash,recovery,created_at,expires_at) VALUES(upper('$sess'),upper('$acct'),'$th','$csh',0,strftime('%s','now'),strftime('%s','now')+86400)"
  else
    tt_mysql_q "INSERT INTO accounts(id,handle,display_name,role,created_at) VALUES(UNHEX(REPLACE('$acct','-','')),'synth-admin','Synthetic Admin','admin',UTC_TIMESTAMP(6));
      INSERT INTO sessions(id,account_id,token_hash,csrf_token_hash,recovery,created_at,expires_at) VALUES(UNHEX(REPLACE('$sess','-','')),UNHEX(REPLACE('$acct','-','')),'$th','$csh',0,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6)+INTERVAL 1 DAY)" "$TEST_DB"
  fi
}

# --- one driver ------------------------------------------------------------------------------------------------------
run_case() { # run_case sqlite|mariadb
  local driver="$1" PORT
  PORT="$([ "$driver" = sqlite ] && echo "$PORT_SQLITE" || echo "$PORT_MARIADB")"
  local base="$WORK/$driver"
  mkdir -p "$base/files" "$base/backups" "$base/data"
  local files; files="$(cd "$base/files" && pwd -P)"
  SQLITE_FILE="$base/data/timetrack.sqlite"
  local key; key="$(openssl rand -base64 32)"
  local dbref
  local -a bk_args rs_args
  if [ "$driver" = sqlite ]; then
    dbref="$SQLITE_FILE"
    bk_args=(--driver sqlite --sqlite-path "$SQLITE_FILE"); rs_args=(--sqlite-path "$SQLITE_FILE")
  else
    dbref="$TEST_DB"
    tt_mysql_q "DROP DATABASE IF EXISTS \`$TEST_DB\`; CREATE DATABASE \`$TEST_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    bk_args=(--driver mariadb --db-container "$TT_DB_CONTAINER" --db-name "$TEST_DB"); rs_args=(--db-container "$TT_DB_CONTAINER" --db-name "$TEST_DB")
  fi
  tt_log "== [$driver] start backend on port $PORT and create synthetic data"
  start_backend "$driver" "$PORT" "$SQLITE_FILE" "$key" true

  local invite; local -a benv
  while IFS= read -r line; do benv+=("$line"); done < <(backend_env "$driver" "$PORT" "$SQLITE_FILE" "$key" true)
  invite="$(env "${benv[@]}" "$APP" bootstrap-admin 2>/dev/null | grep -c '/invite/' || true)"
  check "[$driver] bootstrap-admin CLI prints one invitation link" test "$invite" = 1

  seed_account "$driver"
  local use_s3=0
  if curl -s -o /dev/null -m 3 "$S3_ENDPOINT/"; then use_s3=1; fi
  local rules='[{"maxBytes":2048,"backend":"db"},{"backend":"local"}]' s3json=""
  if [ "$use_s3" = 1 ]; then
    rules='[{"maxBytes":2048,"backend":"db"},{"maxBytes":200000,"backend":"local"},{"backend":"s3"}]'
    s3json=',"s3":{"endpoint":"'"$S3_ENDPOINT"'","region":"us-east-1","bucket":"'"$S3_BUCKET"'","pathStyle":true,"accessKeyId":"dummy-access-key","secretAccessKey":"dummy-secret-key"}'
  else
    tt_log "S3Mock not reachable at $S3_ENDPOINT: S3 part skipped"
  fi
  api PUT /api/v1/admin/storage '{"rules":'"$rules"',"localPath":"'"$files"'"'"$s3json"'}' >/dev/null

  synthetic_pdf "$WORK/f-db.pdf" 1500; synthetic_pdf "$WORK/f-local.pdf" 100000; synthetic_pdf "$WORK/f-s3.pdf" 300000
  local id_db id_local id_s3="" sha_db sha_local sha_s3=""
  id_db="$(upload "$WORK/f-db.pdf")"; sha_db="$(tt_sha256 "$WORK/f-db.pdf")"
  id_local="$(upload "$WORK/f-local.pdf")"; sha_local="$(tt_sha256 "$WORK/f-local.pdf")"
  if [ "$use_s3" = 1 ]; then id_s3="$(upload "$WORK/f-s3.pdf")"; sha_s3="$(tt_sha256 "$WORK/f-s3.pdf")"; fi
  local absence
  absence="$(api POST /api/v1/absences '{"kind":"other","startDate":"2026-12-07","endDate":"2026-12-08","status":"planned","note":"synthetic restore test"}' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
  for f in "$id_db" "$id_local" "$id_s3"; do
    [ -z "$f" ] || api POST "/api/v1/absences/$absence/attachments" '{"fileId":"'"$f"'"}' >/dev/null
  done
  api POST /api/v1/calendar/custom-days '{"kind":"holiday","startDate":"2026-12-24","endDate":"2026-12-24","name":"Synthetic day 1"}' >/dev/null
  api POST /api/v1/calendar/custom-days '{"kind":"school_holiday","startDate":"2026-12-28","endDate":"2027-01-08","name":"Synthetic holidays"}' >/dev/null
  check "[$driver] files readable before backup (db/local${id_s3:+/s3})" test "$(download_sha "$id_db")" = "$sha_db" -a "$(download_sha "$id_local")" = "$sha_local" -a "$(download_sha "${id_s3:-$id_db}")" = "${sha_s3:-$sha_db}"
  check "[$driver] local file exists on disk below the storage root" test -n "$(find "$files" -type f ! -name '.tmp-*' | head -1)"

  tt_log "== [$driver] backup while the backend is running"
  local backup
  backup="$("$ROOT/scripts/backup.sh" "${bk_args[@]}" --local-files "$files" --out "$base/backups" 2>"$base/backup.log" | tail -1)" || { cat "$base/backup.log" >&2; tt_die "backup failed"; }
  check "[$driver] backup directory has manifest, checksums, db and files archive" test -f "$backup/MANIFEST" -a -f "$backup/SHA256SUMS" -a -f "$backup/files.tar.gz"
  check "[$driver] backup (decompressed) contains neither STORAGE_SECRET_KEY, S3 secret nor session token" \
    bash -c '! { for f in "$1"/*; do case "$f" in *.tar.gz) ;; *.gz) gzip -dc "$f" ;; *) cat "$f" ;; esac; done | grep -aqF -e "$2" -e "$3" -e dummy-secret-key; }' _ "$backup" "$key" "$TOKEN"
  local counts_before; counts_before="$(cat "$backup/row_counts.tsv")"

  # a change after the backup must be gone after the restore
  api POST /api/v1/calendar/custom-days '{"kind":"holiday","startDate":"2026-12-31","endDate":"2026-12-31","name":"After backup"}' >/dev/null
  stop_backend

  tt_log "== [$driver] refusal paths"
  check_fail "[$driver] restore into the non-empty target is refused without --force-overwrite" \
    "$ROOT/scripts/restore.sh" --from "$backup" "${rs_args[@]}" --files-target "$files"
  local tampered="$base/tampered"; cp -R "$backup" "$tampered"
  local art; art="$(tt_manifest_get "$tampered/MANIFEST" artifact_db)"
  printf 'x' >>"$tampered/$art"
  check_fail "[$driver] tampered backup is rejected by checksum verification" \
    "$ROOT/scripts/restore.sh" --from "$tampered" "${rs_args[@]}" --files-target "$base/files-tamper" --force-overwrite

  tt_log "== [$driver] wipe database and files"
  if [ "$driver" = sqlite ]; then rm -f "$SQLITE_FILE" "$SQLITE_FILE-wal" "$SQLITE_FILE-shm"
  else tt_mysql_q "DROP DATABASE \`$TEST_DB\`"; fi
  find "$files" -mindepth 1 -delete

  tt_log "== [$driver] restore"
  "$ROOT/scripts/restore.sh" --from "$backup" "${rs_args[@]}" --files-target "$files" --strict-counts 2>"$base/restore.log" || { cat "$base/restore.log" >&2; }
  check "[$driver] restore.sh verified migrations, file checksums and row counts" grep -q "restore verified" "$base/restore.log"
  check "[$driver] restored row counts equal the backup manifest (all tables)" test "$(if [ "$driver" = sqlite ]; then tt_row_counts sqlite "$dbref"; else tt_row_counts mariadb "$dbref"; fi)" = "$counts_before"

  tt_log "== [$driver] start backend on the restored data (AUTO_MIGRATE=false)"
  start_backend "$driver" "$PORT" "$SQLITE_FILE" "$key" false
  check "[$driver] /ready is 200 after restore without running migrations" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/ready")" = 200
  check "[$driver] old session still valid after restore" test "$(curl -s -o /dev/null -w '%{http_code}' -b "tt_session=$TOKEN" "http://127.0.0.1:$PORT/api/v1/auth/session")" = 200
  check "[$driver] DB-stored attachment: API bytes match original sha256" test "$(download_sha "$id_db")" = "$sha_db"
  check "[$driver] local attachment: API bytes match original sha256" test "$(download_sha "$id_local")" = "$sha_local"
  if [ "$use_s3" = 1 ]; then
    check "[$driver] S3 attachment readable via the restored (encrypted) S3 secret + original STORAGE_SECRET_KEY" test "$(download_sha "$id_s3")" = "$sha_s3"
  fi
  local days links
  days="$(api GET '/api/v1/calendar/holidays?year=2026&region=DE-ST' || true)"
  links="$(api GET "/api/v1/absences/$absence/attachments" || true)"
  check "[$driver] custom days from before the backup are back, the post-backup day is gone" \
    bash -c 'grep -q "Synthetic day 1" <<<"$1" && ! grep -q "After backup" <<<"$1"' _ "$days"
  check "[$driver] attachments of the absence are linked (>= 2 file ids)" \
    bash -c '[ "$(grep -o "fileId" <<<"$1" | wc -l | tr -d " ")" -ge 2 ] || [ "$(grep -o "\"id\"" <<<"$1" | wc -l | tr -d " ")" -ge 2 ]' _ "$links"
  stop_backend

  if [ "$use_s3" = 1 ]; then
    tt_log "== [$driver] wrong STORAGE_SECRET_KEY: S3 secret must not decrypt"
    start_backend "$driver" "$PORT" "$SQLITE_FILE" "$(openssl rand -base64 32)" false
    check "[$driver] with a wrong STORAGE_SECRET_KEY the S3 file is unavailable (not served)" test "$(download_sha "$id_s3")" = ERR503
    check "[$driver] with a wrong STORAGE_SECRET_KEY db and local files still work" test "$(download_sha "$id_db")" = "$sha_db" -a "$(download_sha "$id_local")" = "$sha_local"
    stop_backend
    start_backend "$driver" "$PORT" "$SQLITE_FILE" "$key" false
    api DELETE "/api/v1/files/$id_s3" >/dev/null || true   # remove the test object from S3Mock again
    stop_backend
  fi
  RESULTS+=("INFO  [$driver] archive sizes: $(du -sk "$backup" | cut -f1) KiB total, $(tt_manifest_get "$backup/MANIFEST" files_local_archived) local file(s), $(tt_manifest_get "$backup/MANIFEST" migrations_count) migrations, $(wc -l <"$backup/row_counts.tsv" | tr -d ' ') tables")
}

# --- main ------------------------------------------------------------------------------------------------------------
if [ "$CASES" = all ] || [ "$CASES" = mariadb ]; then
  docker inspect "$TT_DB_CONTAINER" >/dev/null 2>&1 || tt_die "container $TT_DB_CONTAINER not running (scripts/dev-env.sh up)"
  case "$TT_DB_CONTAINER" in timetrack-dev-*) ;; *) tt_die "refusing to use a container not named timetrack-dev-*" ;; esac
  MARIADB_ROOT_PW="$(docker exec "$TT_DB_CONTAINER" printenv MARIADB_ROOT_PASSWORD)"
  MARIADB_HOST_PORT="$(docker port "$TT_DB_CONTAINER" 3306/tcp | head -1 | sed 's/.*://')"
  [ -n "$MARIADB_HOST_PORT" ] || tt_die "database container publishes no host port"
fi
if [ "$CASES" = all ] || [ "$CASES" = sqlite ]; then run_case sqlite; fi
if [ "$CASES" = all ] || [ "$CASES" = mariadb ]; then run_case mariadb; fi

echo
printf '%s\n' "${RESULTS[@]}"
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
