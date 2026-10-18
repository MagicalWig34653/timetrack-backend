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

die() { echo "error: $*" >&2; exit 1; }
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

if [ -z "$TAG" ]; then
  echo "Looking up the newest sha- tag of ${IMAGE_BASE} ..."
  TOKEN="$(registry_token)"; [ -n "$TOKEN" ] || die "could not get a registry token (is the package public?)"
  LATEST_DIGEST="$(digest_of latest)"; [ -n "$LATEST_DIGEST" ] || die "tag 'latest' not found on ghcr.io"
  TAGS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list?n=1000" | grep -o '"sha-[0-9a-f]*"' | tr -d '"' || true)"
  [ -n "$TAGS" ] || die "no sha- tags found"
  for candidate in $TAGS; do
    if [ "$(digest_of "$candidate")" = "$LATEST_DIGEST" ]; then TAG="$candidate"; break; fi
  done
  [ -n "$TAG" ] || die "no sha- tag matches latest (${LATEST_DIGEST}); pass --tag explicitly"
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
if [ "$YES" = 0 ]; then
  printf 'Database backed up? Continue with the update? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|j|J|ja) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# Write the new image into the env file (keep a backup copy next to it).
cp "$ENV_FILE" "${ENV_FILE}.bak"
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
awk -v image="$NEW_IMAGE" 'BEGIN{done=0} /^TIMETRACK_IMAGE=/ {print "TIMETRACK_IMAGE=" image; done=1; next} {print} END{if(!done) print "TIMETRACK_IMAGE=" image}' "$ENV_FILE" > "$TMP"
cat "$TMP" > "$ENV_FILE"; rm -f "$TMP"
echo "Wrote TIMETRACK_IMAGE to ${ENV_FILE} (backup: ${ENV_FILE}.bak)."

if [ "$MIGRATE" = 1 ]; then
  MIGRATE_SERVICE="${STACK}_migrate"
  previous="$(docker service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.ID}}' 2>/dev/null | head -n 1 || true)"
  echo "Running the migration job with the new image ..."
  docker service update --force --with-registry-auth --image "$NEW_IMAGE" "$MIGRATE_SERVICE" >/dev/null
  waited=0
  while :; do
    line="$(docker service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.ID}} {{.CurrentState}}' | head -n 1)"
    id="${line%% *}"; state="${line#* }"
    if [ "$id" != "$previous" ]; then
      case "$state" in
        Complete*) echo "Migration finished: ${state}"; break ;;
        Failed*|Rejected*|Shutdown*|Orphaned*)
          echo "Migration did NOT succeed (${state}). Logs:" >&2
          docker service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true
          die "backend not updated; fix the migration first (docs/UPDATE.md)" ;;
      esac
    fi
    [ "$waited" -lt "$WAIT_SECONDS" ] || { docker service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true; die "migration did not finish within ${WAIT_SECONDS}s"; }
    sleep 3; waited=$((waited + 3))
  done
  docker service logs --tail 15 "$MIGRATE_SERVICE" 2>&1 || true
fi

echo "Updating the backend (rolling update) ..."
FORCE_FLAG=""; [ "$FORCE" = 1 ] && FORCE_FLAG="--force"
# shellcheck disable=SC2086
docker service update --with-registry-auth --image "$NEW_IMAGE" $FORCE_FLAG "${STACK}_backend"
docker service ps "${STACK}_backend" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'

BASE_URL="$(sed -n 's/^PUBLIC_BASE_URL=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'")"
if [ -n "$BASE_URL" ]; then
  echo "Readiness: $(curl -fsS "${BASE_URL%/}/ready" 2>&1 || echo 'not ready yet')"
fi
echo "Done. If the app shows a white page once, remove the site data of the domain in your browser."
