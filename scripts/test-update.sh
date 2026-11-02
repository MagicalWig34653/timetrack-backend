#!/usr/bin/env bash
# Offline tests for deploy/swarm/update.sh: runs the real script against stub `docker` (stateful fake Swarm) and uses
# file:// URLs for the self-update. No Swarm, no registry, no network. Usage: scripts/test-update.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD/deploy/swarm"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
FAILS=0; N=0

OLD_IMAGE="ghcr.io/example/timetrack-backend:sha-aaaaaaa"
NEW_TAG="sha-4b42364"
NEW_IMAGE="ghcr.io/example/timetrack-backend:${NEW_TAG}"

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Fake Swarm. State lives in $ST: migrate_exists (0/1), tasks (ids), mode (done|hang|fail), ustate.
echo "docker $*" >> "$ST/log"
args="$*"
exists() { [ "$(cat "$ST/migrate_exists")" = 1 ]; }
nosvc() { echo "Error response from daemon: No such service: $1" >&2; exit 1; }
[ "$1" = info ] && { [ -f "$ST/info_fail" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }; echo "active true"; exit 0; }
if [ "$1 $2" = "service inspect" ]; then
  name="${*: -1}"
  if [ "$name" = timetrack_migrate ]; then exists || nosvc "$name"; echo abc123; exit 0; fi
  case "$args" in
    *ContainerSpec.Image*) echo "ghcr.io/example/timetrack-backend:sha-aaaaaaa@sha256:0123456789abcdef" ;;
    *Replicated.Replicas*) echo 2 ;;
    *UpdateStatus.State*) cat "$ST/ustate" 2>/dev/null || echo completed ;;
    *UpdateStatus.Message*) echo "update paused" ;;
    *) echo abc123 ;;
  esac
  exit 0
fi
if [ "$1 $2" = "service ps" ]; then
  name="$3"
  if [ "$name" = timetrack_migrate ]; then
    exists || nosvc "$name"
    case "$args" in
      *"-q"*) cat "$ST/tasks" 2>/dev/null | cut -d'|' -f1 ;;
      *"{{.ID}}|"*) cat "$ST/tasks" 2>/dev/null | cut -d'|' -f1,2,3,4 ;;
      *"--format"*) cat "$ST/tasks" 2>/dev/null | tail -n 1 | cut -d'|' -f3,4 ;;
      *) cat "$ST/tasks" 2>/dev/null ;;
    esac
    exit 0
  fi
  case "$args" in *"{{.CurrentState}}"*) echo "Running 1 minute ago" ;; *) echo "timetrack_backend.1 node1 img Running" ;; esac
  exit 0
fi
if [ "$1 $2" = "service update" ]; then
  name="${*: -1}"
  if [ "$name" = timetrack_migrate ]; then
    exists || nosvc "$name"
    tid="t$(( $(wc -l < "$ST/tasks") + 1 ))"
    case "$(cat "$ST/mode")" in
      done) echo "$tid|node1|Complete 1 second ago|" >> "$ST/tasks" ;;
      hang) echo "$tid|node1|Running 3 seconds ago|" >> "$ST/tasks" ;;
      fail) echo "$tid|node1|Failed 1 second ago|task: non-zero exit (1)" >> "$ST/tasks" ;;
    esac
    exit 0
  fi
  [ -f "$ST/backend_update_fail" ] && { echo "Error: update failed" >&2; exit 1; }
  exit 0
fi
if [ "$1 $2" = "service ls" ]; then case "$args" in *"{{.Name}}"*) echo "timetrack_backend 2/2" ;; *) echo "2/2" ;; esac; exit 0; fi
if [ "$1 $2" = "service logs" ]; then echo "No new migrations."; exit 0; fi
if [ "$1 $2" = "stack deploy" ]; then
  echo "STACKDEPLOY TIMETRACK_IMAGE=${TIMETRACK_IMAGE:-} BACKEND_REPLICAS=${BACKEND_REPLICAS:-}" >> "$ST/log"
  [ -f "$ST/stack_fail" ] && { echo "failed to create service timetrack_migrate" >&2; exit 1; }
  echo 1 > "$ST/migrate_exists"; echo "t1|node1|Complete 2 seconds ago|" > "$ST/tasks"
  exit 0
fi
echo "unexpected docker call: $*" >&2; exit 99
STUB
chmod +x "$ROOT/bin/docker"

# new_case NAME [migrate_exists] [mode]: fresh sandbox with script, stack file, .env; sets D (dir) and ST (stub state).
new_case() {
  D="$ROOT/$1"; ST="$D/state"; mkdir -p "$D/app" "$ST" "$D/tmp"
  cp "$SRC/update.sh" "$D/app/update.sh"; cp "$SRC/stack.yaml" "$D/app/stack.yaml"
  printf 'TIMETRACK_IMAGE=%s\nPUBLIC_BASE_URL=file://%s/web\nOTHER=1\n' "$OLD_IMAGE" "$D" > "$D/app/.env"
  echo "${2:-1}" > "$ST/migrate_exists"; echo "${3:-done}" > "$ST/mode"
  if [ "${2:-1}" = 1 ]; then echo "t1|node1|Complete 1 hour ago|" > "$ST/tasks"; else : > "$ST/tasks"; fi
  mkdir -p "$D/web"; echo ok > "$D/web/ready"; echo ok > "$D/web/health"
}
# run_case ARGS...: runs the sandbox copy; output in $OUT, exit code in $RC.
run_case() {
  OUT="$(cd "$D/app" && PATH="$ROOT/bin:$PATH" ST="$ST" TMPDIR="$D/tmp" UPDATE_SELF_CHECK="${UPDATE_SELF_CHECK:-0}" MIGRATE_TIMEOUT="${MIGRATE_TIMEOUT:-4}" \
    bash ./update.sh "$@" 2>&1 </dev/null)"; RC=$?
}
check() { # check DESCRIPTION CONDITION-RESULT
  N=$((N + 1))
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); [ -z "${3:-}" ] || echo "     $3"; fi
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
logged() { grep -qF -- "$1" "$ST/log" 2>/dev/null; }
env_image() { sed -n 's/^TIMETRACK_IMAGE=//p' "$1" | tail -n 1; }

# 1. The reported case: migrate service is missing -> restored from the stack file, update completes.
new_case missing 0
run_case --force --yes --tag "$NEW_TAG"
check "missing migrate: exit 0" "$RC" "rc=$RC"$'\n'"$OUT"
check "missing migrate: reported and restored" "$(has 'fehlt' && has 'wiederhergestellt' && echo 0 || echo 1)"
check "missing migrate: stack deploy keeps the running backend image and replicas" "$(logged "STACKDEPLOY TIMETRACK_IMAGE=${OLD_IMAGE} BACKEND_REPLICAS=2" && echo 0 || echo 1)" "$(cat "$ST/log")"
check "missing migrate: job started with the new image" "$(logged "service update --detach --force --with-registry-auth --image ${NEW_IMAGE} timetrack_migrate" && echo 0 || echo 1)"
check "missing migrate: backend rolled to the new image" "$(logged "--image ${NEW_IMAGE} --force timetrack_backend" && echo 0 || echo 1)"
check "missing migrate: .env new, .env.bak old" "$([ "$(env_image "$D/app/.env")" = "$NEW_IMAGE" ] && [ "$(env_image "$D/app/.env.bak")" = "$OLD_IMAGE" ] && echo 0 || echo 1)"
check "missing migrate: ends with Fertig" "$(has 'Fertig nach' && echo 0 || echo 1)"
check "missing migrate: history line written" "$(grep -q 'ok mode=update' "$D/app/update-history.log" && echo 0 || echo 1)"

# 2. Idempotent re-run with --force: .env.bak must keep the OLD image.
run_case --force --yes --tag "$NEW_TAG"
check "force re-run: exit 0" "$RC" "$OUT"
check "force re-run: .env.bak still holds the old image" "$([ "$(env_image "$D/app/.env.bak")" = "$OLD_IMAGE" ] && echo 0 || echo 1)"
check "force re-run: no second stack deploy" "$([ "$(grep -c STACKDEPLOY "$ST/log")" = 1 ] && echo 0 || echo 1)"
run_case --yes --tag "$NEW_TAG"
check "same tag without --force: nothing to do" "$(has 'Nichts zu tun' && [ "$RC" = 0 ] && echo 0 || echo 1)"

# 3. Migrate service exists, job completes.
new_case present 1 "done"
run_case --yes --tag "$NEW_TAG"
check "present migrate: exit 0, no stack deploy" "$([ "$RC" = 0 ] && ! logged STACKDEPLOY && echo 0 || echo 1)" "$OUT"
check "present migrate: confirmation prompt answered by --yes only" "$(has 'Rückfrage übersprungen' && echo 0 || echo 1)"

# 4. Migration hangs: loud timeout, backend untouched.
new_case hang 1 hang
MIGRATE_TIMEOUT=3 run_case --yes --tag "$NEW_TAG"
check "hanging migrate: exit 1 with German message" "$([ "$RC" = 1 ] && has 'nicht fertig' && has 'Hinweise' && echo 0 || echo 1)" "$OUT"
check "hanging migrate: backend not updated" "$(grep -q 'service update.*timetrack_backend' "$ST/log" && echo 1 || echo 0)"

# 5. Migration fails.
new_case failing 1 fail
run_case --yes --tag "$NEW_TAG"
check "failed migrate: exit 1, loud" "$([ "$RC" = 1 ] && has 'NICHT erfolgreich' && echo 0 || echo 1)" "$OUT"

# 6. Missing migrate and no stack file: loud error before anything is changed.
new_case nostack 0
rm "$D/app/stack.yaml"
run_case --yes --tag "$NEW_TAG"
check "no stack file: exit 1 with hint, .env untouched" "$([ "$RC" = 1 ] && has 'Stack-Datei' && [ "$(env_image "$D/app/.env")" = "$OLD_IMAGE" ] && echo 0 || echo 1)" "$OUT"

# 7. stack deploy fails: loud.
new_case stackfail 0; touch "$ST/stack_fail"
run_case --yes --tag "$NEW_TAG"
check "stack deploy failure: exit 1, message" "$([ "$RC" = 1 ] && has 'docker stack deploy ist fehlgeschlagen' && echo 0 || echo 1)" "$OUT"

# 8. An unexpected failing command is never silent (the original bug class).
new_case unexpected 1 "done"; touch "$ST/backend_update_fail"
run_case --yes --tag "$NEW_TAG"
check "unexpected failure: exit non-zero, reports step, command and code" "$([ "$RC" != 0 ] && has 'unerwartet beendet' && has 'Letzter Schritt' && has 'Fehlgeschlagener Befehl' && echo 0 || echo 1)" "$OUT"

# 9. Docker not usable: loud.
new_case nodocker 1; touch "$ST/info_fail"
run_case --yes --tag "$NEW_TAG"
check "docker daemon unreachable: exit 1, message" "$([ "$RC" = 1 ] && has 'docker info ist fehlgeschlagen' && echo 0 || echo 1)" "$OUT"

# 10. Dry run changes nothing.
new_case dry 0
run_case --dry-run --tag "$NEW_TAG"
check "dry run: exit 0, plan shown, migrate reported missing" "$([ "$RC" = 0 ] && has 'Trockenlauf' && has 'FEHLT' && echo 0 || echo 1)" "$OUT"
check "dry run: .env unchanged, no write calls" "$([ "$(env_image "$D/app/.env")" = "$OLD_IMAGE" ] && ! [ -f "$D/app/.env.bak" ] && ! logged 'service update' && ! logged 'stack deploy' && echo 0 || echo 1)"

# 11. Backup hook failure stops before the migration.
new_case backup 1
UPDATE_BACKUP_CMD=false run_case --yes --tag "$NEW_TAG"
check "backup command failure: exit 1, job not started" "$([ "$RC" = 1 ] && has 'UPDATE_BACKUP_CMD' && ! logged 'service update' && echo 0 || echo 1)" "$OUT"

# 12. Status.
new_case status 1
run_case --status
check "status healthy: exit 0" "$([ "$RC" = 0 ] && has 'alles in Ordnung' && echo 0 || echo 1)" "$OUT"
new_case status_bad 0
run_case --status
check "status with missing migrate: exit 1, PROBLEM line" "$([ "$RC" = 1 ] && has 'PROBLEM' && has "timetrack_migrate fehlt" && echo 0 || echo 1)" "$OUT"

# 13. Rollback to the previous image from .env.bak.
new_case rollback 1
run_case --yes --tag "$NEW_TAG"
run_case --rollback --yes
check "rollback: exit 0, .env back on the old image" "$([ "$RC" = 0 ] && [ "$(env_image "$D/app/.env")" = "$OLD_IMAGE" ] && echo 0 || echo 1)" "$OUT"
check "rollback: backend updated to the old image, migrate untouched" "$(logged "--image ${OLD_IMAGE} timetrack_backend" && [ "$(grep -c 'update.*timetrack_migrate' "$ST/log")" = 1 ] && echo 0 || echo 1)"
new_case rollback_none 1
run_case --rollback --yes
check "rollback without .env.bak: exit 1, message" "$([ "$RC" = 1 ] && has 'Keine Sicherung' && echo 0 || echo 1)" "$OUT"

# 14. Lock: a live lock blocks, a stale one is removed.
new_case lock 1
mkdir -p "$D/tmp/timetrack-update-timetrack.lock"; echo $$ > "$D/tmp/timetrack-update-timetrack.lock/pid"
run_case --yes --tag "$NEW_TAG"
check "live lock: exit 1, message" "$([ "$RC" = 1 ] && has 'anderer update.sh-Lauf' && echo 0 || echo 1)" "$OUT"
echo 999999 > "$D/tmp/timetrack-update-timetrack.lock/pid"
run_case --yes --tag "$NEW_TAG"
check "stale lock: removed, update runs" "$([ "$RC" = 0 ] && has 'Veraltete Sperre' && echo 0 || echo 1)" "$OUT"

# 15. Self update from a file:// "deploy branch".
new_case selfupd 1
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="9.9.9"/' "$SRC/update.sh" > "$D/remote.sh"
UPDATE_SCRIPT_URL="file://$D/remote.sh" run_case --self-update --yes
check "self-update: replaced, .prev kept, new version" "$([ "$RC" = 0 ] && grep -q '"9.9.9"' "$D/app/update.sh" && [ -f "$D/app/update.sh.prev" ] && has 'Bitte das Skript neu starten' && echo 0 || echo 1)" "$OUT"
UPDATE_SCRIPT_URL="file://$D/remote.sh" run_case --self-update --yes
check "self-update again: already current" "$([ "$RC" = 0 ] && has 'Bereits aktuell' && echo 0 || echo 1)" "$OUT"
head -n 20 "$SRC/update.sh" > "$D/truncated.sh"
cp "$SRC/update.sh" "$D/app/update.sh"
UPDATE_SCRIPT_URL="file://$D/truncated.sh" run_case --self-update --yes
check "self-update with truncated download: refused, script unchanged" "$([ "$RC" = 1 ] && has 'kein vollständiges update.sh' && cmp -s "$SRC/update.sh" "$D/app/update.sh" && echo 0 || echo 1)" "$OUT"
UPDATE_SCRIPT_URL="file://$D/remote.sh" run_case --self-update --dry-run
check "self-update --dry-run: nothing changed" "$([ "$RC" = 0 ] && cmp -s "$SRC/update.sh" "$D/app/update.sh" && echo 0 || echo 1)" "$OUT"
new_case hint 1
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="9.9.9"/' "$SRC/update.sh" > "$D/remote.sh"
UPDATE_SELF_CHECK=1 UPDATE_SCRIPT_URL="file://$D/remote.sh" run_case --dry-run --tag "$NEW_TAG"
check "start hint: newer script announced, nothing replaced" "$(has 'anderes update.sh' && echo 0 || echo 1)" "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then echo "test-update: all $N checks passed"; else echo "test-update: $FAILS of $N checks FAILED"; exit 1; fi
