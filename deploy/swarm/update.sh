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
# main build, so the sha- tag that points to the same digest as `latest` is the newest build. Needs curl and docker.
# Back up the database first (docs/installation/backup.md). See docs/UPDATE.md.
set -euo pipefail

STACK=timetrack
ENV_FILE=""
TAG=""
DRY=0
FORCE=0
YES=0
MIGRATE=1
WAIT_SECONDS=300

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
die() { echo "[$(elapsed)] error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need curl
[ "$DRY" = 1 ] || need docker

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
  curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${REPO}:pull" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
# Digest of a tag (empty when the tag does not exist).
digest_of() {
  curl -fsSI -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}

step "Find the newest image tag"
if [ -z "$TAG" ]; then
  say "Registry: ghcr.io, repository ${REPO}"
  TOKEN="$(registry_token)"; [ -n "$TOKEN" ] || die "could not get a registry token (is the package public?)"
  say "Registry token received."
  LATEST_DIGEST="$(digest_of latest)"; [ -n "$LATEST_DIGEST" ] || die "tag 'latest' not found on ghcr.io"
  say "latest = ${LATEST_DIGEST}"
  TAGS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list?n=1000" | grep -o '"sha-[0-9a-f]*"' | tr -d '"' || true)"
  [ -n "$TAGS" ] || die "no sha- tags found"
  TOTAL="$(printf '%s\n' "$TAGS" | wc -l | tr -d ' ')"
  say "${TOTAL} sha- tags found, comparing their digests with latest ..."
  n=0
  for candidate in $TAGS; do
    n=$((n + 1))
    if [ "$(digest_of "$candidate")" = "$LATEST_DIGEST" ]; then TAG="$candidate"; say "  [${n}/${TOTAL}] ${candidate}  <- matches latest"; break; fi
    say "  [${n}/${TOTAL}] ${candidate}  (not latest)"
  done
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
if [ "$YES" = 0 ]; then
  printf 'Database backed up? Continue with the update? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|j|J|ja) ;; *) echo "Aborted."; exit 1 ;; esac
else
  say "Confirmation skipped (--yes)."
fi

step "Write the new image into ${ENV_FILE}"

# Write the new image into the env file (keep a backup copy next to it).
cp "$ENV_FILE" "${ENV_FILE}.bak"
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
awk -v image="$NEW_IMAGE" 'BEGIN{done=0} /^TIMETRACK_IMAGE=/ {print "TIMETRACK_IMAGE=" image; done=1; next} {print} END{if(!done) print "TIMETRACK_IMAGE=" image}' "$ENV_FILE" > "$TMP"
cat "$TMP" > "$ENV_FILE"; rm -f "$TMP"
echo "Wrote TIMETRACK_IMAGE to ${ENV_FILE} (backup: ${ENV_FILE}.bak)."

if [ "$MIGRATE" = 1 ]; then
  MIGRATE_SERVICE="${STACK}_migrate"
  previous="$(docker service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.ID}}' 2>/dev/null | head -n 1 || true)"
  step "Run the database migration (job ${MIGRATE_SERVICE})"
  say "Starting the job with ${NEW_IMAGE} (the image is pulled on the node; this can take a minute) ..."
  docker service update --detach --force --with-registry-auth --image "$NEW_IMAGE" "$MIGRATE_SERVICE" >/dev/null
  waited=0; last_state=""
  while :; do
    line="$(docker service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.ID}} {{.Node}} {{.CurrentState}}' | head -n 1)"
    id="${line%% *}"; rest="${line#* }"; node="${rest%% *}"; state="${rest#* }"
    # strip the changing "... 3 seconds ago" part so only real state changes are printed
    shown="${state%% [0-9]*}"; shown="${shown%% about*}"
    if [ "$id" != "$previous" ] && [ "$shown" != "$last_state" ]; then say "migration task on ${node}: ${shown}"; last_state="$shown"; fi
    if [ "$id" != "$previous" ]; then
      case "$state" in
        Complete*) say "Migration finished."; break ;;
        Failed*|Rejected*|Shutdown*|Orphaned*)
          echo "Migration did NOT succeed (${state}). Logs:" >&2
          docker service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true
          die "backend not updated; fix the migration first (docs/UPDATE.md)" ;;
      esac
    fi
    [ "$waited" -lt "$WAIT_SECONDS" ] || { docker service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true; die "migration did not finish within ${WAIT_SECONDS}s"; }
    sleep 2; waited=$((waited + 2))
    if [ $((waited % 20)) -eq 0 ]; then say "  ... still waiting for the migration (${waited}s)"; fi
  done
  say "Migration log (last lines):"
  docker service logs --tail 15 "$MIGRATE_SERVICE" 2>&1 | sed 's/^/    /' || true
else
  step "Database migration"
  say "Skipped (--skip-migrate)."
fi

step "Update the backend (rolling update, one replica after the other)"
BACKEND="${STACK}_backend"
FORCE_FLAG=""; [ "$FORCE" = 1 ] && FORCE_FLAG="--force"
# shellcheck disable=SC2086
docker service update --detach --with-registry-auth --image "$NEW_IMAGE" $FORCE_FLAG "$BACKEND" >/dev/null
say "Update started; watching the rollout ..."
waited=0; last=""
while :; do
  ustate="$(docker service inspect "$BACKEND" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
  replicas="$(docker service ls --filter "name=${BACKEND}" --format '{{.Replicas}}' | head -n 1)"
  running="$(docker service ps "$BACKEND" --filter desired-state=running --format '{{.CurrentState}}' | sed 's/ .*//' | sort | uniq -c | awk '{printf "%s %s, ", $1, $2}' | sed 's/, $//')"
  now="update=${ustate:-none} replicas=${replicas} tasks: ${running}"
  if [ "$now" != "$last" ]; then say "$now"; last="$now"; fi
  case "$ustate" in
    completed) say "Rollout completed."; break ;;
    paused|rollback_started|rollback_completed|rollback_paused)
      docker service inspect "$BACKEND" --format '{{.UpdateStatus.Message}}' >&2 || true
      docker service ps "$BACKEND" --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}' | head -n 6 >&2 || true
      die "rollout did not succeed (${ustate}); Swarm rolls back automatically, see docs/UPDATE.md" ;;
  esac
  [ "$waited" -lt 600 ] || die "rollout did not finish within 600s (see: docker service ps ${BACKEND})"
  sleep 3; waited=$((waited + 3))
done
docker service ps "$BACKEND" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'

step "Check the result"
BASE_URL="$(sed -n 's/^PUBLIC_BASE_URL=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
if [ -n "$BASE_URL" ]; then
  say "GET ${BASE_URL%/}/ready -> $(curl -fsS "${BASE_URL%/}/ready" 2>&1 || echo 'not ready yet')"
  say "GET ${BASE_URL%/}/health -> $(curl -fsS "${BASE_URL%/}/health" 2>&1 | head -c 300 || echo 'no answer')"
else
  say "PUBLIC_BASE_URL is not set in the env file; skipping the readiness check."
fi
say "Done in $(elapsed). If the app shows a white page once, remove the site data of the domain in your browser."
