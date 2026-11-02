#!/usr/bin/env bash
# Update a running Swarm stack to the newest published image: find the newest `sha-<commit>` tag on GHCR,
# write it into .env (TIMETRACK_IMAGE), run the migration job with the new image, then roll the backend.
#
# Usage: deploy/swarm/update.sh [options]
#   --env-file FILE   stack variables (default: ./.env, else the file next to this script)
#   --tag TAG         use this tag (e.g. sha-6c074f7 or 0.1.0) instead of looking up the newest sha- tag
#   --stack NAME      stack name (default: timetrack)
#   --dry-run         only show what would happen (no file change, no docker calls)
#   --force           also restart the services when the tag did not change
#   --yes             do not ask for confirmation
#   --skip-migrate    only update the backend (not recommended)
#
# How the newest tag is found: `latest` is pushed together with `sha-<commit>` by the Docker workflow on every
# main build, so the sha- tag that points to the same digest as `latest` is the newest build. It is found in constant time via
# the image label org.opencontainers.image.revision (verified against the digest of latest); comparing all tags is only a fallback. Needs curl and docker.
# Back up the database first (docs/installation/backup.md). See docs/UPDATE.md.
set -euo pipefail

STACK=timetrack
ENV_FILE=""
TAG=""
DRY=0
FORCE=0
YES=0
MIGRATE=1
# Wall-clock limits (seconds) for the two waiting phases; override through the environment if the node is slow.
WAIT_SECONDS="${MIGRATE_TIMEOUT:-300}"
ROLLOUT_SECONDS="${ROLLOUT_TIMEOUT:-600}"
# Every single docker/curl call is bounded too, so a stuck daemon or registry cannot hang the script silently.
CALL_TIMEOUT=60

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --tag) TAG="${2:?missing value for --tag}"; shift 2 ;;
    --stack) STACK="${2:?missing value for --stack}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --skip-migrate) MIGRATE=0; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done

START_TIME=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START_TIME )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
STEP=0; STEPS=6
step() { STEP=$((STEP + 1)); printf '\n[%s] == Step %d/%d: %s\n' "$(elapsed)" "$STEP" "$STEPS" "$*"; }
die() { echo "[$(elapsed)] error: $*" >&2; [ "$PHASE" = start ] || hints; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need curl
[ "$DRY" = 1 ] || need docker

# Bounded wrappers. `timeout` (coreutils) exists on Linux Swarm managers; without it the calls run unbounded as before.
if command -v timeout >/dev/null 2>&1; then
  dk() { timeout "$CALL_TIMEOUT" docker "$@"; }
else
  dk() { docker "$@"; }
fi
# --max-time keeps a stalled registry or proxy from blocking forever (the total wait is also bounded by the phase limits).
curlb() { curl --connect-timeout 10 --max-time 30 "$@"; }

# Shown when the script stops early or fails: what is running, how to look closer, how to go back.
PHASE="start"
OLD_IMAGE_FOR_HINT=""
hints() {
  [ "$DRY" = 0 ] || return 0
  {
    echo "---- Hinweise (Phase: ${PHASE}) ----"
    echo "Der Befehl bricht nur dieses Skript ab; Swarm führt Migration bzw. Rolling Update weiter aus."
    echo "Status ansehen:  docker service ps ${STACK}_migrate --no-trunc"
    echo "                 docker service ps ${STACK}_backend --no-trunc"
    echo "                 docker service inspect ${STACK}_backend --format '{{json .UpdateStatus}}'"
    echo "Logs:            docker service logs --tail 100 ${STACK}_migrate"
    echo "                 docker service logs --tail 100 ${STACK}_backend"
    echo "Zurück zum alten Stand (Backend): docker service rollback ${STACK}_backend"
    [ -z "$OLD_IMAGE_FOR_HINT" ] || echo "Alter Stand in der .env: ${OLD_IMAGE_FOR_HINT} (Sicherung: ${ENV_FILE:-.env}.bak)"
  } >&2
}
on_interrupt() { echo >&2; echo "[$(elapsed)] Abbruch durch Benutzer." >&2; hints; exit 130; }
trap on_interrupt INT TERM

if [ -z "$ENV_FILE" ]; then
  if [ -f ./.env ]; then ENV_FILE=./.env
  elif [ -f "$(dirname "$0")/.env" ]; then ENV_FILE="$(dirname "$0")/.env"
  else die "no .env found; pass --env-file"; fi
fi
[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"

CURRENT_IMAGE="$(sed -n 's/^TIMETRACK_IMAGE=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
[ -n "$CURRENT_IMAGE" ] || die "TIMETRACK_IMAGE is not set in $ENV_FILE"
case "$CURRENT_IMAGE" in
  ghcr.io/*) ;;
  *) [ -n "$TAG" ] || die "automatic lookup only supports ghcr.io images; pass --tag" ;;
esac
# ghcr.io/owner/name:tag -> repository "owner/name", image base "ghcr.io/owner/name"
IMAGE_BASE="${CURRENT_IMAGE%:*}"
case "$IMAGE_BASE" in */*) ;; *) die "cannot parse image name: $CURRENT_IMAGE" ;; esac
REPO="${IMAGE_BASE#*/}"
CURRENT_TAG="${CURRENT_IMAGE##*:}"

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

registry_token() {
  curlb -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${REPO}:pull" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
# Digest of a tag (empty when the tag does not exist).
digest_of() {
  curlb -fsSI -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}

# Commit the image of a tag was built from (label org.opencontainers.image.revision); empty when it cannot be read.
# Prints the value of one image label of a tag (empty when missing).
label_of() {
  local name="$2" index manifest config
  index="$(curlb -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1")" || return 1
  # An index lists platform manifests (plus attestations); a plain manifest has its own config.
  manifest="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"digest":"sha256:[0-9a-f]*","size":[0-9]*,"platform":{"architecture":"\(amd64\|arm64\)"' | head -1 | grep -o 'sha256:[0-9a-f]*')"
  if [ -n "$manifest" ]; then
    index="$(curlb -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/${manifest}")" || return 1
  fi
  config="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"config":{[^}]*}' | grep -o 'sha256:[0-9a-f]*' | head -1)"
  [ -n "$config" ] || return 1
  curlb -fsSL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/blobs/${config}" \
    | grep -o "\"${name}\":\"[0-9a-f]*\"" | head -1 | sed 's/.*:"\([0-9a-f]*\)"/\1/'
}
revision_of() { label_of "$1" org.opencontainers.image.revision; }

step "Find the newest image tag"
if [ -z "$TAG" ]; then
  say "Registry: ghcr.io, repository ${REPO}"
  TOKEN="$(registry_token)"; [ -n "$TOKEN" ] || die "could not get a registry token (is the package public?)"
  say "Registry token received."
  LATEST_DIGEST="$(digest_of latest)"; [ -n "$LATEST_DIGEST" ] || die "tag 'latest' not found on ghcr.io"
  say "latest = ${LATEST_DIGEST}"
  # Fast path (constant time): the image carries its commit in the label org.opencontainers.image.revision, so the
  # tag is sha-<first 7 characters>. latest -> index -> first platform manifest -> config blob -> label (4 requests).
  # The result is verified against the digest of latest; if anything is missing the slow scan below runs instead.
  REVISION="$(revision_of latest || true)"
  PWA_REVISION="$(label_of latest dev.timetrack.pwa-revision || true)"
  if [ -n "$REVISION" ]; then
    # Builds also happen when only the PWA changed, so sha-<commit> alone is not unique: prefer sha-<commit>-<pwa commit>.
    candidates="sha-${REVISION:0:7}"
    [ -z "$PWA_REVISION" ] || candidates="sha-${REVISION:0:7}-${PWA_REVISION:0:7} ${candidates}"
    for candidate in $candidates; do
      if [ "$(digest_of "$candidate")" = "$LATEST_DIGEST" ]; then TAG="$candidate"; say "latest was built from commit ${REVISION:0:7} -> ${candidate} (verified)"; break; fi
    done
  fi
  if [ -z "$TAG" ]; then
    say "Label lookup did not give a verified tag, falling back to comparing all sha- tags (slow with many images) ..."
    TAGS="$(curlb -fsS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list?n=1000" | grep -o '"sha-[0-9a-f-]*"' | tr -d '"' || true)"
    [ -n "$TAGS" ] || die "no sha- tags found"
    TOTAL="$(printf '%s\n' "$TAGS" | wc -l | tr -d ' ')"
    say "${TOTAL} sha- tags found, comparing their digests with latest ..."
    n=0
    for candidate in $TAGS; do
      n=$((n + 1))
      if [ "$(digest_of "$candidate")" = "$LATEST_DIGEST" ]; then TAG="$candidate"; say "  [${n}/${TOTAL}] ${candidate}  <- matches latest"; break; fi
      say "  [${n}/${TOTAL}] ${candidate}  (not latest)"
    done
  fi
  [ -n "$TAG" ] || die "no sha- tag matches latest (${LATEST_DIGEST}); pass --tag explicitly"
else
  say "Using the tag from --tag: ${TAG}"
fi

NEW_IMAGE="${IMAGE_BASE}:${TAG}"
echo "Stack:     ${STACK}"
echo "Env file:  ${ENV_FILE}"
echo "Current:   ${CURRENT_IMAGE}"
echo "New:       ${NEW_IMAGE}"

if [ "$NEW_IMAGE" = "$CURRENT_IMAGE" ] && [ "$FORCE" = 0 ]; then
  echo "Already on the newest tag. Nothing to do (use --force to restart anyway)."
  exit 0
fi
if [ "$DRY" = 1 ]; then
  echo "Dry run: would set TIMETRACK_IMAGE, run ${STACK}_migrate, then update ${STACK}_backend."
  exit 0
fi
step "Confirm"
# One run at a time: a second run would start the migration job again while the first one is still waiting.
LOCK_DIR="${TMPDIR:-/tmp}/timetrack-update-${STACK}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "another update.sh run for stack ${STACK} seems to be active (lock ${LOCK_DIR}, pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')). If no run is active, remove the directory and retry."
fi
echo "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT
if [ "$YES" = 0 ]; then
  printf 'Database backed up? Continue with the update? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|j|J|ja) ;; *) echo "Aborted."; exit 1 ;; esac
else
  say "Confirmation skipped (--yes)."
fi

step "Write the new image into ${ENV_FILE}"

# Write the new image into the env file (keep a backup copy next to it).
OLD_IMAGE_FOR_HINT="$CURRENT_IMAGE"; PHASE="env-file"
cp "$ENV_FILE" "${ENV_FILE}.bak"
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
awk -v image="$NEW_IMAGE" 'BEGIN{done=0} /^TIMETRACK_IMAGE=/ {print "TIMETRACK_IMAGE=" image; done=1; next} {print} END{if(!done) print "TIMETRACK_IMAGE=" image}' "$ENV_FILE" > "$TMP"
cat "$TMP" > "$ENV_FILE"; rm -f "$TMP"
echo "Wrote TIMETRACK_IMAGE to ${ENV_FILE} (backup: ${ENV_FILE}.bak)."

if [ "$MIGRATE" = 1 ]; then
  MIGRATE_SERVICE="${STACK}_migrate"
  # Tasks that exist before the update; everything else is a task of this run (docker service ps is not sorted by age).
  before=" $(dk service ps "$MIGRATE_SERVICE" -q --no-trunc 2>/dev/null | tr '\n' ' ')"
  step "Run the database migration (job ${MIGRATE_SERVICE})"
  PHASE="migration"
  say "Starting the job with ${NEW_IMAGE} (the image is pulled on the node; this can take a minute) ..."
  dk service update --detach --force --with-registry-auth --image "$NEW_IMAGE" "$MIGRATE_SERVICE" >/dev/null
  # Wall clock (SECONDS), not a sum of sleeps: slow docker calls count against the limit as well.
  phase_start=$SECONDS; last_state=""; running_since=""; stall_reported=""
  while :; do
    waited=$((SECONDS - phase_start))
    outcome=""; shown=""; reason=""
    while IFS='|' read -r id node state err; do
      [ -n "$id" ] || continue
      case "$before" in *" $id "*) continue ;; esac
      # strip the changing "... 3 seconds ago" part so only real state changes are printed
      word="${state%% *}"
      case "$word" in
        Complete) outcome=complete; shown="Complete on ${node}"; break ;;
        Failed|Rejected|Orphaned) outcome=failed; shown="${state} on ${node}"; reason="$err" ;;
        *) [ -n "$shown" ] || { shown="${word} on ${node:-<not scheduled yet>}"; reason="$err"; } ;;
      esac
    done <<EOF
$(dk service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.ID}}|{{.Node}}|{{.CurrentState}}|{{.Error}}' 2>/dev/null || true)
EOF
    [ -n "$shown" ] || shown="waiting for the scheduler"
    if [ "$shown" != "$last_state" ]; then say "migration task: ${shown}${reason:+ (${reason})}"; last_state="$shown"; fi
    case "$outcome" in
      complete) say "Migration finished."; break ;;
      failed)
        echo "Migration did NOT succeed (${shown}). Logs:" >&2
        dk service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true
        die "backend not updated; fix the migration first (docs/UPDATE.md)" ;;
    esac
    # A task that stays "Running" although the migration already reported its end means the process hangs on shutdown.
    case "$shown" in Running*) [ -n "$running_since" ] || running_since=$SECONDS ;; *) running_since="" ;; esac
    if [ -n "$running_since" ] && [ $((SECONDS - running_since)) -ge 60 ] && [ -z "$stall_reported" ]; then
      if dk service logs --tail 20 "$MIGRATE_SERVICE" 2>&1 | grep -qE 'No new migrations|Migration successful|Finished prepare'; then
        say "WARNING: the migration log already shows its end, but the task has been Running for $((SECONDS - running_since))s: the process seems to hang while shutting down (database pool?). The schema is probably current."
        stall_reported=1
      fi
    fi
    if [ "$waited" -ge "$WAIT_SECONDS" ]; then
      echo "Migration task list:" >&2
      dk service ps "$MIGRATE_SERVICE" --no-trunc >&2 || true
      echo "Last log lines:" >&2
      dk service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true
      die "migration did not finish within ${WAIT_SECONDS}s (state: ${shown}). The backend was NOT touched. If the log shows 'No new migrations' the schema is current and a hanging shutdown is the problem; see docs/DEPLOYMENT.md (Fehlersuche beim Update)."
    fi
    sleep 2
  done
  say "Migration log (last lines):"
  dk service logs --tail 15 "$MIGRATE_SERVICE" 2>&1 | sed 's/^/    /' || true
else
  step "Database migration"
  say "Skipped (--skip-migrate)."
fi

step "Update the backend (rolling update, one replica after the other)"
PHASE="rollout"
BACKEND="${STACK}_backend"
FORCE_FLAG=""; [ "$FORCE" = 1 ] && FORCE_FLAG="--force"
# shellcheck disable=SC2086
dk service update --detach --with-registry-auth --image "$NEW_IMAGE" $FORCE_FLAG "$BACKEND" >/dev/null
say "Update started; watching the rollout ..."
phase_start=$SECONDS; last=""
while :; do
  waited=$((SECONDS - phase_start))
  ustate="$(dk service inspect "$BACKEND" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
  replicas="$(dk service ls --filter "name=${BACKEND}" --format '{{.Replicas}}' 2>/dev/null | head -n 1 || true)"
  running="$(dk service ps "$BACKEND" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | sed 's/ .*//' | sort | uniq -c | awk '{printf "%s %s, ", $1, $2}' | sed 's/, $//' || true)"
  now="update=${ustate:-none} replicas=${replicas} tasks: ${running}"
  if [ "$now" != "$last" ]; then say "$now"; last="$now"; fi
  case "$ustate" in
    completed) say "Rollout completed."; break ;;
    paused|rollback_started|rollback_completed|rollback_paused)
      dk service inspect "$BACKEND" --format '{{.UpdateStatus.Message}}' >&2 || true
      dk service ps "$BACKEND" --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}' | head -n 6 >&2 || true
      die "rollout did not succeed (${ustate}); Swarm rolls back automatically, see docs/UPDATE.md" ;;
  esac
  if [ "$waited" -ge "$ROLLOUT_SECONDS" ]; then
    echo "Backend task list:" >&2
    dk service ps "$BACKEND" --no-trunc >&2 || true
    echo "Last log lines:" >&2
    dk service logs --tail 40 "$BACKEND" >&2 || true
    die "rollout did not finish within ${ROLLOUT_SECONDS}s (update=${ustate:-none}). New tasks stay unhealthy while /ready fails (database unreachable, pool timeouts, schema not current). Swarm keeps updating or rolls back on its own."
  fi
  sleep 3
done
dk service ps "$BACKEND" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'

step "Check the result"
PHASE="check"
BASE_URL="$(sed -n 's/^PUBLIC_BASE_URL=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
if [ -n "$BASE_URL" ]; then
  say "GET ${BASE_URL%/}/ready -> $(curlb -fsS "${BASE_URL%/}/ready" 2>&1 || echo 'not ready yet')"
  say "GET ${BASE_URL%/}/health -> $(curlb -fsS "${BASE_URL%/}/health" 2>&1 | head -c 300 || echo 'no answer')"
else
  say "PUBLIC_BASE_URL is not set in the env file; skipping the readiness check."
fi
say "Done in $(elapsed). If the app shows a white page once, remove the site data of the domain in your browser."
