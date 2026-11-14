#!/usr/bin/env bash
# Update a running Swarm stack to the newest published image (or roll it back), and keep this script current.
#
# Update flow: find the newest `sha-<commit>` tag on GHCR, write it into .env (TIMETRACK_IMAGE, backup .env.bak), run
# the migration job with the new image, then roll the backend (and an active `<stack>_backend-pinned`) and check /ready. A missing `<stack>_migrate` service
# (for example removed by hand) is recreated from the stack file instead of aborting. Every abort is reported loudly
# (step, line, command, exit code); the script never ends silently. Details: docs/DEPLOYMENT.md, docs/UPDATE.md.
# Language: code and comments are English, all output for the operator is German.
set -Eeuo pipefail

SCRIPT_VERSION="2.4.0"
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

STACK=timetrack
ENV_FILE=""
STACK_FILE=""
OVERRIDES=()           # extra Compose files merged after the stack file (--stack-override, STACK_OVERRIDE_FILES)
TAG=""
MODE=update            # update | status | rollback | self-update | version
DRY=0
FORCE=0
APPLY_DRIFT=0
DRIFT=0
MISSING_SECRETS=0
DRIFT_DIR=""
YES=0
MIGRATE=1
SELF_CHECK="${UPDATE_SELF_CHECK:-1}"
SCRIPT_URL="${UPDATE_SCRIPT_URL:-}"
SCRIPT_REF="${UPDATE_SCRIPT_REF:-deploy}"
# Wall-clock limits (seconds) for the two waiting phases; override through the environment if the node is slow.
WAIT_SECONDS="${MIGRATE_TIMEOUT:-300}"
ROLLOUT_SECONDS="${ROLLOUT_TIMEOUT:-600}"
# Every single docker/curl call is bounded too, so a stuck daemon or registry cannot hang the script silently.
CALL_TIMEOUT=60
STACK_DEPLOY_TIMEOUT=180

usage() {
  cat <<'EOF'
update.sh: Timetrack-Stack auf Docker Swarm aktualisieren, prüfen, zurücksetzen

Aufruf: update.sh [Modus] [Optionen]
Modi (Standard: Update auf das neueste Image):
  --status          Zustand anzeigen (Stand, Dienste, Migrationsjob, /ready); ändert nichts, Exit 1 bei Problemen
  --rollback        Backend auf das Image aus .env.bak zurücksetzen (das Datenbankschema wird NICHT zurückgesetzt)
  --self-update     dieses Skript vom deploy-Branch holen (zeigt Unterschiede, fragt nach, sichert update.sh.prev)
  --version         Skriptversion anzeigen
Optionen:
  --env-file FILE   Stack-Variablen (Standard: ./.env, sonst die Datei neben dem Skript)
  --stack-file FILE Stack-Datei für Driftprüfung und Wiederherstellung (Standard: stack.yaml neben dem Skript)
  --stack-override FILE  zusätzliche Compose-Datei (Overlay) hinter der Stack-Datei, wiederholbar (auch STACK_OVERRIDE_FILES, durch Leerzeichen getrennt)
  --tag TAG         diesen Tag verwenden (z. B. sha-6c074f7 oder 0.1.0) statt des neuesten sha-Tags
  --stack NAME      Stack-Name (Standard: timetrack)
  --dry-run         nur anzeigen, was passieren würde (keine Änderung; nur lesende docker-Aufrufe)
  --apply-stack-drift  erkannte Konfigurationsabweichungen per Stack-Deploy übernehmen (alle Dienste betroffen)
  --force           auch ohne Tag-Wechsel neu starten (idempotent: .env.bak bleibt erhalten)
  --yes, -y         keine Rückfragen
  --skip-migrate    nur das Backend aktualisieren (nicht empfohlen)
  --script-url URL  Quelle für --self-update (Standard: raw-URL des deploy-Branches, aus dem Image-Namen abgeleitet)
  --script-ref REF  Branch oder Commit-Hash für --self-update (Standard: deploy; ein Commit-Hash pinnt den Stand)
  --no-self-check   beim Start nicht prüfen, ob es ein neueres update.sh gibt
Umgebung: MIGRATE_TIMEOUT, ROLLOUT_TIMEOUT (Sekunden), UPDATE_BACKUP_CMD (Befehl, der vor der Migration läuft;
  Fehlschlag bricht das Update ab), UPDATE_SCRIPT_URL, UPDATE_SCRIPT_REF, UPDATE_SELF_CHECK=0, NO_COLOR.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?Wert für --env-file fehlt}"; shift 2 ;;
    --stack-file) STACK_FILE="${2:?Wert für --stack-file fehlt}"; shift 2 ;;
    --stack-override) OVERRIDES+=("${2:?Wert für --stack-override fehlt}"); shift 2 ;;
    --tag) TAG="${2:?Wert für --tag fehlt}"; shift 2 ;;
    --stack) STACK="${2:?Wert für --stack fehlt}"; shift 2 ;;
    --script-url) SCRIPT_URL="${2:?Wert für --script-url fehlt}"; shift 2 ;;
    --script-ref) SCRIPT_REF="${2:?Wert für --script-ref fehlt}"; shift 2 ;;
    --status) MODE=status; shift ;;
    --rollback) MODE=rollback; shift ;;
    --self-update) MODE=self-update; shift ;;
    --version) MODE=version; shift ;;
    --dry-run) DRY=1; shift ;;
    --apply-stack-drift) APPLY_DRIFT=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --skip-migrate) MIGRATE=0; shift ;;
    --no-self-check) SELF_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done
[[ "$STACK" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "Ungültiger Stack-Name: $STACK" >&2; exit 64; }
if [ "$MODE" = version ]; then echo "update.sh Version ${SCRIPT_VERSION}"; exit 0; fi

# ---- output ----------------------------------------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
else C_RED=""; C_YEL=""; C_GRN=""; C_OFF=""; fi
START_TIME=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START_TIME )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
good() { printf '[%s] %s%s%s\n' "$(elapsed)" "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '[%s] %sWarnung: %s%s\n' "$(elapsed)" "$C_YEL" "$*" "$C_OFF" >&2; }
STEP=0; STEPS=6; STEP_NAME="Start"
step() { STEP=$((STEP + 1)); STEP_NAME="$*"; printf '\n[%s] == Schritt %d/%d: %s\n' "$(elapsed)" "$STEP" "$STEPS" "$*"; }

# ---- error handling: never end silently --------------------------------------------------------------------------------
PHASE="start"            # coarse phase for the hints
REPORTED=0               # 1 once an error message was printed
ERR_RC=0; ERR_LINE=0; ERR_CMD=""
HISTORY=0                # 1 once a real run started (then the outcome is appended to the history file)
LOCK_DIR=""
OLD_IMAGE_FOR_HINT=""
NEW_IMAGE=""; CURRENT_IMAGE=""
trap 'ERR_RC=$?; ERR_LINE=$LINENO; ERR_CMD=$BASH_COMMAND' ERR

hints() {
  [ "$DRY" = 0 ] || return 0
  {
    echo "---- Hinweise (Phase: ${PHASE}) ----"
    echo "Das Skript ist beendet; Swarm führt eine begonnene Migration bzw. ein Rolling Update trotzdem weiter."
    echo "Zustand ansehen:  $0 --status${ENV_FILE:+ --env-file ${ENV_FILE}}"
    echo "                  docker service ps ${STACK}_migrate --no-trunc"
    echo "                  docker service ps ${STACK}_backend --no-trunc"
    echo "Logs:             docker service logs --tail 100 ${STACK}_migrate"
    echo "                  docker service logs --tail 100 ${STACK}_backend"
    echo "Zurück (Backend): $0 --rollback${ENV_FILE:+ --env-file ${ENV_FILE}}   oder   docker service rollback ${STACK}_backend"
    [ -z "$OLD_IMAGE_FOR_HINT" ] || echo "Alter Stand in der .env: ${OLD_IMAGE_FOR_HINT} (Sicherung: ${ENV_FILE:-.env}.bak)"
  } >&2
}
die() {
  REPORTED=1
  printf '[%s] %sFehler: %s%s\n' "$(elapsed)" "$C_RED" "$1" "$C_OFF" >&2
  [ "$PHASE" = start ] || hints
  exit "${2:-1}"
}
record_history() {
  [ "$HISTORY" = 1 ] && [ -n "$ENV_FILE" ] || return 0
  printf '%s %s mode=%s stack=%s rc=%s from=%s to=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$MODE" "$STACK" "$2" "${OLD_IMAGE_FOR_HINT:--}" "${NEW_IMAGE:--}" \
    >> "$(dirname "$ENV_FILE")/update-history.log" 2>/dev/null || true
}
on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM
  [ -z "$LOCK_DIR" ] || rm -rf "$LOCK_DIR"
  [ -z "$DRIFT_DIR" ] || rm -rf "$DRIFT_DIR"
  if [ "$rc" -ne 0 ] && [ "$REPORTED" = 0 ]; then
    {
      printf '[%s] %sFehler: Das Skript wurde unerwartet beendet (Exit-Code %s).%s\n' "$(elapsed)" "$C_RED" "$rc" "$C_OFF"
      echo "  Letzter Schritt: ${STEP}/${STEPS} ${STEP_NAME} (Phase: ${PHASE})"
      [ "$ERR_LINE" = 0 ] || echo "  Fehlgeschlagener Befehl: ${ERR_CMD} (Zeile ${ERR_LINE}, Exit-Code ${ERR_RC})"
    } >&2
    [ "$PHASE" = start ] || hints
  fi
  if [ "$rc" -eq 0 ]; then record_history ok "$rc"; else record_history failed "$rc"; fi
}
on_signal() { REPORTED=1; echo >&2; echo "[$(elapsed)] Abbruch durch Benutzer/Signal ($1)." >&2; [ "$PHASE" = start ] || hints; exit "$2"; }
trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

need() { command -v "$1" >/dev/null 2>&1 || die "$1 wird benötigt, ist aber nicht installiert."; }
need curl
# docker is optional only for the read-only parts that can run without it (self-update, dry-run of an update).
if [ "$MODE" != self-update ] && ! { [ "$MODE" = update ] && [ "$DRY" = 1 ]; }; then need docker; fi

# Bounded wrappers. `timeout` (coreutils) exists on Linux Swarm managers; without it the calls run unbounded.
if command -v timeout >/dev/null 2>&1; then
  dk() { timeout "$CALL_TIMEOUT" docker "$@"; }
  dkl() { timeout "$STACK_DEPLOY_TIMEOUT" docker "$@"; }
else
  dk() { docker "$@"; }
  dkl() { docker "$@"; }
fi
curlb() { curl --connect-timeout 10 --max-time 30 "$@"; }

# ---- env file and image names ------------------------------------------------------------------------------------------
if [ -z "$ENV_FILE" ]; then
  if [ -f ./.env ]; then ENV_FILE=./.env
  elif [ -f "$SCRIPT_DIR/.env" ]; then ENV_FILE="$SCRIPT_DIR/.env"
  else die "Keine .env gefunden (weder ./.env noch neben dem Skript). Mit --env-file angeben."; fi
fi
[ -f "$ENV_FILE" ] || die "Env-Datei nicht gefunden: $ENV_FILE"
env_get() { sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d "\"'" || true; }
if [ -z "$STACK_FILE" ]; then
  if [ -f "$SCRIPT_DIR/stack.yaml" ]; then STACK_FILE="$SCRIPT_DIR/stack.yaml"; elif [ -f ./stack.yaml ]; then STACK_FILE=./stack.yaml; fi
fi
# Overlay files: --stack-override (repeatable) plus STACK_OVERRIDE_FILES (space separated); all must exist.
if [ -n "${STACK_OVERRIDE_FILES:-}" ]; then
  read -r -a _env_overrides <<< "$STACK_OVERRIDE_FILES"
  OVERRIDES+=("${_env_overrides[@]}")
fi
STACK_C_ARGS=()
for _f in ${OVERRIDES[@]+"${OVERRIDES[@]}"}; do
  [ -f "$_f" ] || die "Overlay-Datei nicht gefunden: $_f"
  STACK_C_ARGS+=(-c "$_f")
done

CURRENT_IMAGE="$(env_get "$ENV_FILE" TIMETRACK_IMAGE)"
[ -n "$CURRENT_IMAGE" ] || die "TIMETRACK_IMAGE ist in $ENV_FILE nicht gesetzt."
case "$CURRENT_IMAGE" in
  ghcr.io/*) ;;
  *) [ -n "$TAG" ] || [ "$MODE" != update ] || die "Die automatische Suche unterstützt nur ghcr.io-Images; mit --tag angeben." ;;
esac
# ghcr.io/owner/name:tag -> repository "owner/name", image base "ghcr.io/owner/name"
IMAGE_BASE="${CURRENT_IMAGE%:*}"
case "$IMAGE_BASE" in */*) ;; *) die "Image-Name nicht lesbar: $CURRENT_IMAGE" ;; esac
REPO="${IMAGE_BASE#*/}"
BACKEND="${STACK}_backend"
PINNED="${STACK}_backend-pinned"   # optional second service with the same image (PINNED_NODE/PINNED_REPLICAS)
MIGRATE_SERVICE="${STACK}_migrate"
BASE_URL="$(env_get "$ENV_FILE" PUBLIC_BASE_URL)"

# ---- docker helpers ----------------------------------------------------------------------------------------------------
# 0 = exists, 1 = does not exist; any other docker failure (daemon, timeout, not a manager) is fatal and loud.
service_exists() {
  local out
  if out="$(dk service inspect --format '{{.ID}}' "$1" 2>&1)"; then return 0; fi
  case "$out" in
    *"No such service"*|*"no such service"*) return 1 ;;
    *) die "docker service inspect $1 ist fehlgeschlagen: ${out:-keine Ausgabe (Zeitüberschreitung?)}" ;;
  esac
}
# Prints the value of a Go template for a service; never fails (empty when the service or field is missing).
svc_field() { dk service inspect --format "$2" "$1" 2>/dev/null | head -n 1 || true; }
# Task ids of a service, one per line; never fails (a missing service gives an empty list).
task_ids() { dk service ps "$1" -q --no-trunc 2>/dev/null || true; }
# Replica count of the pinned service when it exists and is active (> 0), else empty.
pinned_active() {
  local n
  service_exists "$PINNED" || return 0
  n="$(svc_field "$PINNED" '{{.Spec.Mode.Replicated.Replicas}}')"
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]; then printf '%s' "$n"; fi
}
# Replica state ("2/2") of exactly this service; `service ls --filter name=` matches by prefix (backend -> backend-pinned).
svc_replicas() { dk service ls --filter "name=$1" --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v n="$1" '$1==n {print $2}' | head -n 1 || true; }
ensure_manager() {
  local out
  out="$(dk info --format '{{.Swarm.LocalNodeState}} {{.Swarm.ControlAvailable}}' 2>&1)" || die "docker info ist fehlgeschlagen: ${out:-keine Ausgabe}. Läuft der Docker-Dienst, und darfst du ihn benutzen?"
  [ "$out" = "active true" ] || die "Dieser Host ist kein Swarm-Manager (Zustand: ${out}). Das Skript muss auf einem Manager-Knoten laufen."
}

# ---- registry lookup (newest sha- tag) ---------------------------------------------------------------------------------
ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
registry_token() {
  curlb -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${REPO}:pull" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
# Digest of a tag (empty when the tag does not exist).
digest_of() {
  curlb -fsSI -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}
# Prints the value of one image label of a tag (empty when missing).
label_of() {
  local name="$2" index manifest config
  index="$(curlb -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/$1")" || return 1
  # An index lists platform manifests (plus attestations); a plain manifest has its own config.
  manifest="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"digest":"sha256:[0-9a-f]*","size":[0-9]*,"platform":{"architecture":"\(amd64\|arm64\)"' | head -1 | grep -o 'sha256:[0-9a-f]*' || true)"
  if [ -n "$manifest" ]; then
    index="$(curlb -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT" "https://ghcr.io/v2/${REPO}/manifests/${manifest}")" || return 1
  fi
  config="$(printf '%s' "$index" | tr -d '\n ' | grep -o '"config":{[^}]*}' | grep -o 'sha256:[0-9a-f]*' | head -1 || true)"
  [ -n "$config" ] || return 1
  curlb -fsSL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/blobs/${config}" \
    | grep -o "\"${name}\":\"[0-9a-f]*\"" | head -1 | sed 's/.*:"\([0-9a-f]*\)"/\1/' || true
}
revision_of() { label_of "$1" org.opencontainers.image.revision; }

find_newest_tag() {
  say "Registry: ghcr.io, Repository ${REPO}"
  TOKEN="$(registry_token || true)"; [ -n "$TOKEN" ] || die "Kein Registry-Token erhalten (Netzwerk? Ist das Paket öffentlich?)."
  say "Registry-Token erhalten."
  LATEST_DIGEST="$(digest_of latest || true)"; [ -n "$LATEST_DIGEST" ] || die "Tag 'latest' auf ghcr.io nicht gefunden."
  say "latest = ${LATEST_DIGEST}"
  # Fast path (constant time): the image carries its commit in the label org.opencontainers.image.revision, so the
  # tag is sha-<first 7 characters>. latest -> index -> first platform manifest -> config blob -> label (4 requests).
  # The result is verified against the digest of latest; if anything is missing the slow scan below runs instead.
  local REVISION PWA_REVISION candidates candidate TAGS TOTAL n
  REVISION="$(revision_of latest || true)"
  PWA_REVISION="$(label_of latest dev.timetrack.pwa-revision || true)"
  if [ -n "$REVISION" ]; then
    # Builds also happen when only the PWA changed, so sha-<commit> alone is not unique: prefer sha-<commit>-<pwa commit>.
    candidates="sha-${REVISION:0:7}"
    [ -z "$PWA_REVISION" ] || candidates="sha-${REVISION:0:7}-${PWA_REVISION:0:7} ${candidates}"
    for candidate in $candidates; do
      if [ "$(digest_of "$candidate" || true)" = "$LATEST_DIGEST" ]; then TAG="$candidate"; say "latest stammt aus Commit ${REVISION:0:7} -> ${candidate} (verifiziert)"; break; fi
    done
  fi
  if [ -z "$TAG" ]; then
    say "Die Label-Suche ergab keinen verifizierten Tag; vergleiche alle sha-Tags (langsam bei vielen Images) ..."
    TAGS="$(curlb -fsS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list?n=1000" | grep -o '"sha-[0-9a-f-]*"' | tr -d '"' || true)"
    [ -n "$TAGS" ] || die "Keine sha-Tags gefunden."
    TOTAL="$(printf '%s\n' "$TAGS" | wc -l | tr -d ' ')"
    say "${TOTAL} sha-Tags gefunden, vergleiche ihre Digests mit latest ..."
    n=0
    for candidate in $TAGS; do
      n=$((n + 1))
      if [ "$(digest_of "$candidate" || true)" = "$LATEST_DIGEST" ]; then TAG="$candidate"; say "  [${n}/${TOTAL}] ${candidate}  <- entspricht latest"; break; fi
      say "  [${n}/${TOTAL}] ${candidate}  (nicht latest)"
    done
  fi
  [ -n "$TAG" ] || die "Kein sha-Tag entspricht latest (${LATEST_DIGEST}); mit --tag ausdrücklich angeben."
}

# ---- self update (from the source-free deploy branch) --------------------------------------------------------------------
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
script_url() {
  if [ -n "$SCRIPT_URL" ]; then printf '%s' "$SCRIPT_URL"
  else printf 'https://raw.githubusercontent.com/%s/%s/deploy/swarm/update.sh' "$REPO" "$SCRIPT_REF"; fi
}
# Downloads the published script into $1 and checks that it is complete (shebang, syntax, version, end marker).
# Returns 1 when the download failed, 2 when the file is not a complete update.sh.
fetch_script() {
  local dest="$1" max="${2:-30}"
  curl --connect-timeout 10 --max-time "$max" -fsSL "$(script_url)" -o "$dest" 2>/dev/null || return 1
  [ "$(head -n 1 "$dest")" = "#!/usr/bin/env bash" ] || return 2
  grep -q '^SCRIPT_VERSION="' "$dest" || return 2
  [ "$(tail -n 1 "$dest")" = "# END update.sh" ] || return 2
  bash -n "$dest" 2>/dev/null || return 2
}
remote_version() { sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$1" | head -n 1; }
# Quiet hint at the start of an update: never overwrites anything, never fails the run.
self_check_hint() {
  local tmp rc=0
  tmp="$(mktemp)"
  fetch_script "$tmp" 5 || rc=$?
  if [ "$rc" = 0 ] && [ "$(sha_of "$tmp")" != "$(sha_of "$SCRIPT_PATH")" ]; then
    warn "Auf dem deploy-Branch liegt ein anderes update.sh (Version $(remote_version "$tmp"), hier ${SCRIPT_VERSION}). Mit '$0 --self-update' ansehen und übernehmen."
  fi
  rm -f "$tmp"
}
do_self_update() {
  local tmp rc=0 remote_sha local_sha answer
  say "update.sh Version ${SCRIPT_VERSION}; Quelle: $(script_url)"
  tmp="$(mktemp)"
  fetch_script "$tmp" || rc=$?
  case "$rc" in
    0) ;;
    1) rm -f "$tmp"; die "Download fehlgeschlagen (Netzwerk, falsche URL oder Branch/Commit nicht vorhanden): $(script_url)" ;;
    *) rm -f "$tmp"; die "Die heruntergeladene Datei ist kein vollständiges update.sh (Kopfzeile, Version, Endmarke oder Syntax falsch). Nichts wurde geändert." ;;
  esac
  remote_sha="$(sha_of "$tmp")"; local_sha="$(sha_of "$SCRIPT_PATH")"
  if [ "$remote_sha" = "$local_sha" ]; then good "Bereits aktuell (Version ${SCRIPT_VERSION}, sha256 ${local_sha:0:16})."; rm -f "$tmp"; return 0; fi
  say "Lokal:   Version ${SCRIPT_VERSION}, sha256 ${local_sha}"
  say "Neu:     Version $(remote_version "$tmp"), sha256 ${remote_sha}"
  if command -v diff >/dev/null 2>&1; then
    say "Unterschiede (höchstens 80 Zeilen):"
    { diff -u "$SCRIPT_PATH" "$tmp" || true; } | head -n 80
  fi
  if [ "$DRY" = 1 ]; then say "Trockenlauf: nichts wurde geändert."; rm -f "$tmp"; return 0; fi
  if [ "$YES" = 0 ]; then
    printf 'Dieses Skript durch die neue Version ersetzen? Die alte bleibt als %s.prev erhalten. [j/N] ' "$SCRIPT_PATH"
    read -r answer || answer=""
    case "$answer" in y|Y|yes|j|J|ja) ;; *) rm -f "$tmp"; say "Abgebrochen, nichts wurde geändert."; return 0 ;; esac
  fi
  cp -p "$SCRIPT_PATH" "${SCRIPT_PATH}.prev"
  chmod 755 "$tmp"
  mv "$tmp" "$SCRIPT_PATH"
  good "update.sh wurde auf Version $(remote_version "$SCRIPT_PATH") aktualisiert (alte Version: ${SCRIPT_PATH}.prev). Bitte das Skript neu starten."
}

# ---- shared actions ----------------------------------------------------------------------------------------------------
acquire_lock() {
  # One run at a time: a second run would start the migration job again while the first one is still waiting.
  local lock="${TMPDIR:-/tmp}/timetrack-update-${STACK}.lock" other
  if ! mkdir "$lock" 2>/dev/null; then
    other="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && ! kill -0 "$other" 2>/dev/null; then
      warn "Veraltete Sperre von Prozess ${other} (läuft nicht mehr) wird entfernt."
      rm -rf "$lock"; mkdir "$lock" || die "Sperre ${lock} konnte nicht angelegt werden."
    else
      die "Ein anderer update.sh-Lauf für den Stack ${STACK} scheint aktiv zu sein (Sperre ${lock}, PID ${other:-?}). Läuft keiner, das Verzeichnis löschen und neu starten."
    fi
  fi
  LOCK_DIR="$lock"
  echo "$$" > "$LOCK_DIR/pid"
}
confirm() {
  local answer
  if [ "$YES" = 1 ]; then say "Rückfrage übersprungen (--yes)."; return 0; fi
  printf '%s [j/N] ' "$1"
  read -r answer || answer=""
  case "$answer" in y|Y|yes|j|J|ja) ;; *) echo "Abgebrochen."; REPORTED=1; exit 1 ;; esac
}
# Writes TIMETRACK_IMAGE into the env file. The backup .env.bak is only (re)written when the image changes (or when
# there is none yet), so repeating a run with --force never overwrites the saved old state with the new one.
write_env_image() {
  local image="$1" tmp
  if [ "$image" != "$CURRENT_IMAGE" ] || [ ! -f "${ENV_FILE}.bak" ]; then cp -p "$ENV_FILE" "${ENV_FILE}.bak"; fi
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  awk -v image="$image" 'BEGIN{done=0} /^TIMETRACK_IMAGE=/ {print "TIMETRACK_IMAGE=" image; done=1; next} {print} END{if(!done) print "TIMETRACK_IMAGE=" image}' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  say "TIMETRACK_IMAGE wurde in ${ENV_FILE} geschrieben (Sicherung: ${ENV_FILE}.bak)."
}

# Render with exactly the same interpolation context as deployment. Never echo rendered data or Docker diagnostics:
# both may contain credentials, including variables with innocuous names. Private files are removed by on_exit.
check_stack_drift() {
  command -v jq >/dev/null 2>&1 || die "Die Driftprüfung benötigt jq. Bitte jq auf dem Swarm-Manager installieren."
  [ -n "$STACK_FILE" ] && [ -f "$STACK_FILE" ] || die "Stack-Datei für die Driftprüfung nicht gefunden; --stack-file angeben."
  [ -z "$DRIFT_DIR" ] || rm -rf "$DRIFT_DIR"
  DRIFT_DIR="$(umask 077; mktemp -d)"
  # shellcheck disable=SC1090
  ( set +u; set -a; . "$ENV_FILE"; set +a
    dk stack config -c "$STACK_FILE" ${STACK_C_ARGS[@]+"${STACK_C_ARGS[@]}"} ) >"$DRIFT_DIR/stack" 2>/dev/null \
    || die "docker stack config ist fehlgeschlagen (Details zum Schutz von Zugangsdaten unterdrückt). Pflichtvariablen und Overlays prüfen."
  dk service inspect --format '{{json .Spec}}' "$BACKEND" >"$DRIFT_DIR/service" 2>/dev/null || die "Backend-Konfiguration nicht lesbar."
  dk network ls --no-trunc --format '{{.ID}} {{.Name}}' >"$DRIFT_DIR/networks" 2>/dev/null || die "Netzwerkliste nicht lesbar."
  dk secret ls --format '{{.Name}}' >"$DRIFT_DIR/secrets" 2>/dev/null || die "Secret-Liste nicht lesbar."
  local rc=0
  # Docker emits normalized YAML, not JSON. Read only the compared sections, using its two-space indentation.
  # Scalar text stays private; jq decodes quoted strings after awk has recorded paths and sequence indices.
  if ! awk '
    function quote(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "\\r", s)
      gsub(/\n/, "\\n", s); return "\"" s "\""
    }
    function emit(value, literal, i, path) {
      path=""
      for (i=0; i<=depth; i++) path=path (i ? "," : "") (numeric[i] ? keys[i] : quote(keys[i]))
      print "{\"path\":[" path "],\"value\":" quote(value) ",\"literal\":" (literal ? "true" : "false") "}"
    }
    function flush() {
      if (block) {
        if (chomp != "-") text=text "\n"
        emit(text, 1); block=0
      }
    }
    {
      match($0, /[^ ]/); indent=RSTART-1
      if (block && (RSTART==0 || indent>blockindent)) {
        line=substr($0, blockindent+3)
        text=text (lines++ ? "\n" : "") line; next
      }
      flush()
      if (RSTART==0) next
      line=substr($0, indent+1)
      if (indent==0) root=line
      if (indent==2 && root=="services:") service=line
      if (indent==4 && root=="services:" && service=="backend:") section=line
      wanted=((root=="secrets:" || root=="networks:") && (indent<=2 || (indent==4 && line ~ /^(name|external):/)))
      if (root=="services:" && service=="backend:") {
        wanted=(section=="environment:" || section=="secrets:" ||
          (section=="networks:" && indent<=6) || (section=="deploy:" && indent==6 && line ~ /^replicas:/))
      }
      # Keep ancestors so the same paths work regardless of section ordering.
      depth=int(indent/2); numeric[depth]=0
      if (line ~ /^- /) {
        numeric[depth]=1; keys[depth]=count[indent]++; depth++; numeric[depth]=0
        line=substr(line,3)
      } else count[indent+2]=0
      pos=index(line, ":")
      if (!pos) { if (wanted) exit 1; next }
      key=substr(line,1,pos-1); value=substr(line,pos+1); sub(/^ /,"",value)
      keys[depth]=key
      if (root=="services:" && indent==2 && key=="backend") { emit("{}",0); next }
      if (!wanted || value=="") next
      if (value ~ /^[|][+-]?$/) {
        block=1; blockindent=indent; chomp=substr(value,2); text=""; lines=0; next
      }
      emit(value,0)
    }
    END { flush() }
  ' "$DRIFT_DIR/stack" >"$DRIFT_DIR/records" 2>/dev/null; then
    rc=12
  else
    jq -n --arg stack "$STACK" --slurpfile records "$DRIFT_DIR/records" \
      --slurpfile service "$DRIFT_DIR/service" --rawfile networks "$DRIFT_DIR/networks" --rawfile available "$DRIFT_DIR/secrets" '
      def scalar:
        if startswith("\"") then
          [scan("\\\\(?:x[0-9A-Fa-f]{2}|.)|[^\\\\]+") |
            if startswith("\\x") then "\\u00"+.[2:]
            elif . == "\\a" then "\\u0007" elif . == "\\v" then "\\u000b"
            elif . == "\\e" then "\\u001b" elif . == "\\0" then "\\u0000"
            elif . == "\\N" then "\\u0085" elif . == "\\_" then "\\u00a0"
            elif . == "\\L" then "\\u2028" elif . == "\\P" then "\\u2029"
            else . end] | join("") | fromjson
        elif startswith("\u0027") then .[1:-1] | gsub("\u0027\u0027"; "\u0027")
        elif . == "null" or . == "~" then null
        elif . == "{}" then {} elif . == "[]" then []
        else . end;
      def names: sort | map(if test("^[A-Za-z_][A-Za-z0-9_.-]*$") then . else "<Name verborgen>" end) | join(", ");
      def difference($a; $b): (($a - $b) + ($b - $a)) | unique;
      (reduce $records[] as $r ({}; setpath(($r.path | map(if type == "string" then scalar else . end)); if $r.literal then $r.value else ($r.value | scalar) end))) as $config |
      $config.services.backend as $backend | $service[0] as $spec |
      if ($backend | type) != "object" or ($spec.Mode.Replicated.Replicas | type) != "number" then error("invalid configuration") else . end |
      $spec.TaskTemplate.ContainerSpec as $container |
      (($backend.environment // {}) | with_entries(select(.value != null))) as $desired |
      (reduce ($container.Env // [])[] as $v ({}; ($v | index("=")) as $i |
        if $i == null then .[$v]="" else .[$v[0:$i]]=$v[$i+1:] end)) as $actual |
      [($desired + $actual | keys[]) as $k | select($desired[$k] != $actual[$k]) | $k] as $env |
      ($config.secrets // {}) as $definitions |
      def secret_name($key): $definitions[$key] as $d |
        $d.name // (if ($d.external | type)=="object" then $d.external.name else null end) //
        (if $d.external then $key else $stack+"_"+$key end);
      [($backend.secrets // [])[] | . as $s | [secret_name($s.source), ($s.target // $s.source), ($s.uid // "0"), ($s.gid // "0"), (($s.mode // "292") | tonumber)]] | unique as $expectedSecrets |
      [($container.Secrets // [])[] | [.SecretName,.File.Name,.File.UID,.File.GID,.File.Mode]] | unique as $actualSecrets |
      difference($expectedSecrets; $actualSecrets) as $secrets |
      ((($backend.deploy.replicas // "1") | tonumber) != $spec.Mode.Replicated.Replicas) as $replicas |
      (reduce ($networks | split("\n")[] | select(length>0) | split(" ")) as $n ({}; .[$n[0]]=$n[1])) as $ids |
      [($backend.networks // {default:{}} | keys[]) as $key | ($config.networks[$key] // {}) as $d |
        $d.name // (if $d.external then $key else $stack+"_"+$key end)] | unique as $expectedNetworks |
      [($spec.TaskTemplate.Networks // [])[] | $ids[.Target] // .Target] | unique as $actualNetworks |
      difference($expectedNetworks; $actualNetworks) as $nets |
      ([$definitions | to_entries[] | select(.value.external) | secret_name(.key)] - ($available | split("\n"))) as $missing |
      (if ($env|length)>0 then "Konfigurationsdrift: Umgebungsvariablen weichen ab (nur Namen): " + ($env|names) else empty end),
      (if ($secrets|length)>0 then "Konfigurationsdrift: Secret-Zuordnungen weichen ab: " + ([$secrets[][0]]|unique|names) else empty end),
      (if $replicas then "Konfigurationsdrift: Replikazahl weicht ab; beim Abgleich bleibt die laufende Anzahl erhalten." else empty end),
      (if ($nets|length)>0 then "Konfigurationsdrift: Netzwerkzuordnungen weichen ab: " + ($nets|names) else empty end),
      (if ($missing|length)>0 then "Fehlende Swarm-Secrets: " + ($missing|names) + ". Vor dem Deploy create-secrets.sh --add-only ausführen; bei eigenen Secret-Namen die Zuordnung prüfen." else empty end),
      (if ($missing|length)>0 then 11 elif ($env|length)>0 or ($secrets|length)>0 or $replicas or ($nets|length)>0 then 10 else 0 end)
    ' >"$DRIFT_DIR/result" 2>/dev/null || rc=12
    if [ "$rc" = 0 ]; then
      rc="$(tail -n 1 "$DRIFT_DIR/result")"
      sed '$d' "$DRIFT_DIR/result" | jq -r .
    fi
  fi
  DRIFT=0; MISSING_SECRETS=0
  case "$rc" in
    0) good "Keine Konfigurationsdrift im Backend erkannt." ;;
    10) DRIFT=1 ;;
    11) DRIFT=1; MISSING_SECRETS=1 ;;
    *) die "Driftprüfung fehlgeschlagen; keine Änderungen durchgeführt." ;;
  esac
}

# Shared by the drift reconciliation and the missing migration-service restore. Preserve the exact image digest.
deploy_current_stack() {
  local run_image replicas
  [ "$MISSING_SECRETS" = 0 ] || die "Secrets fehlen: zuerst create-secrets.sh --add-only ausführen."
  run_image="$(svc_field "$BACKEND" '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
  replicas="$(svc_field "$BACKEND" '{{.Spec.Mode.Replicated.Replicas}}')"
  [ -n "$run_image" ] && [[ "$replicas" =~ ^[0-9]+$ ]] || die "Laufendes Image oder Replikazahl nicht sicher lesbar."
  # A final overlay also overrides literal image/replica settings in operator overlays.
  jq -n --arg image "$run_image" --argjson replicas "$replicas" \
    '{services:{backend:{image:$image,deploy:{replicas:$replicas}}}}' >"$DRIFT_DIR/preserve.json"
  say "Gleiche den Stack ab (alle Dienste; laufendes Backend-Image und Replikazahl bleiben erhalten)."
  # shellcheck disable=SC1090
  ( set +u; set -a; . "$ENV_FILE"; set +a; export TIMETRACK_IMAGE="$run_image" BACKEND_REPLICAS="$replicas"
    dkl stack deploy --with-registry-auth --resolve-image never -c "$STACK_FILE" ${STACK_C_ARGS[@]+"${STACK_C_ARGS[@]}"} -c "$DRIFT_DIR/preserve.json" "$STACK" ) >/dev/null 2>&1 \
    || die "docker stack deploy ist fehlgeschlagen (Details zum Schutz von Zugangsdaten unterdrückt). Secrets mit create-secrets.sh --add-only prüfen; Pflichtvariablen, Overlays und Zeitüberschreitung prüfen."
  watch_rollout
}

# Recreates the one-shot migrate service from the stack file without changing the running backend: the stack is
# deployed with the image and replica count the backend runs with right now. (Other changed .env values would
# roll the backend too; that is what `docker stack deploy` does for any changed service.)
restore_migrate_service() {
  local tries=0
  say "Der Dienst ${MIGRATE_SERVICE} fehlt; stelle ihn aus der Stack-Datei wieder her."
  deploy_current_stack
  while [ "$tries" -lt 20 ]; do
    if service_exists "$MIGRATE_SERVICE"; then good "Dienst ${MIGRATE_SERVICE} wiederhergestellt."; return 0; fi
    tries=$((tries + 1)); sleep 2
  done
  die "Nach dem Stack-Deploy existiert ${MIGRATE_SERVICE} nach 40 s immer noch nicht. Prüfen: docker stack services ${STACK}"
}

run_migration() {
  local before phase_start last_state running_since stall_reported waited outcome shown reason id node state err word
  # Tasks that exist before the update; everything else is a task of this run (docker service ps is not sorted by age).
  before=" $(task_ids "$MIGRATE_SERVICE" | tr '\n' ' ')"
  say "Starte den Job mit ${NEW_IMAGE} (das Image wird auf dem Knoten geladen, das kann eine Minute dauern) ..."
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
        Complete) outcome=complete; shown="Complete auf ${node}"; break ;;
        Failed|Rejected|Orphaned) outcome=failed; shown="${state} auf ${node}"; reason="$err" ;;
        *) [ -n "$shown" ] || { shown="${word} auf ${node:-<noch nicht zugewiesen>}"; reason="$err"; } ;;
      esac
    done <<EOF
$(dk service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.ID}}|{{.Node}}|{{.CurrentState}}|{{.Error}}' 2>/dev/null || true)
EOF
    [ -n "$shown" ] || shown="warte auf den Scheduler"
    if [ "$shown" != "$last_state" ]; then say "Migrations-Task: ${shown}${reason:+ (${reason})}"; last_state="$shown"; fi
    case "$outcome" in
      complete) good "Migration abgeschlossen."; break ;;
      failed)
        echo "Die Migration war NICHT erfolgreich (${shown}). Log:" >&2
        dk service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true
        die "Das Backend wurde nicht aktualisiert; zuerst die Migration reparieren (docs/UPDATE.md)." ;;
    esac
    # A task that stays "Running" although the migration already reported its end means the process hangs on shutdown.
    case "$shown" in Running*) [ -n "$running_since" ] || running_since=$SECONDS ;; *) running_since="" ;; esac
    if [ -n "$running_since" ] && [ $((SECONDS - running_since)) -ge 60 ] && [ -z "$stall_reported" ]; then
      if dk service logs --tail 20 "$MIGRATE_SERVICE" 2>&1 | grep -qE 'No new migrations|Migration successful|Finished prepare'; then
        warn "Das Migrationslog zeigt schon sein Ende, aber der Task läuft seit $((SECONDS - running_since)) s: Der Prozess hängt offenbar beim Beenden (Datenbank-Pool?). Das Schema ist wahrscheinlich aktuell."
        stall_reported=1
      fi
    fi
    if [ "$waited" -ge "$WAIT_SECONDS" ]; then
      echo "Task-Liste der Migration:" >&2
      dk service ps "$MIGRATE_SERVICE" --no-trunc >&2 || true
      echo "Letzte Logzeilen:" >&2
      dk service logs --tail 40 "$MIGRATE_SERVICE" >&2 || true
      die "Die Migration wurde in ${WAIT_SECONDS} s nicht fertig (Zustand: ${shown}). Das Backend wurde NICHT angefasst. Zeigt das Log 'No new migrations', ist das Schema aktuell und ein hängendes Beenden das Problem; siehe docs/DEPLOYMENT.md (Fehlersuche beim Update)."
    fi
    sleep 2
  done
  say "Migrationslog (letzte Zeilen):"
  dk service logs --tail 15 "$MIGRATE_SERVICE" 2>&1 | sed 's/^/    /' || true
}

# watch_rollout [SERVICE]: waits for the rolling update of SERVICE (default: the backend).
watch_rollout() {
  local svc="${1:-$BACKEND}" phase_start waited ustate replicas running now last=""
  phase_start=$SECONDS
  while :; do
    waited=$((SECONDS - phase_start))
    ustate="$(dk service inspect "$svc" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
    replicas="$(svc_replicas "$svc")"
    running="$(dk service ps "$svc" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | sed 's/ .*//' | sort | uniq -c | awk '{printf "%s %s, ", $1, $2}' | sed 's/, $//' || true)"
    now="Update=${ustate:-keins} Replikas=${replicas} Tasks: ${running}"
    if [ "$now" != "$last" ]; then say "$now"; last="$now"; fi
    case "$ustate" in
      completed) good "Rollout abgeschlossen."; break ;;
      "")
        case "$replicas" in
          */*) if [ "${replicas%%/*}" = "${replicas##*/}" ]; then good "Alle Replikas laufen; kein Rollout offen."; break; fi ;;
        esac ;;
      paused|rollback_started|rollback_completed|rollback_paused)
        dk service inspect "$svc" --format '{{.UpdateStatus.Message}}' >&2 || true
        dk service ps "$svc" --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}' | head -n 6 >&2 || true
        die "Das Rollout war nicht erfolgreich (${ustate}); Swarm setzt automatisch zurück, siehe docs/UPDATE.md." ;;
    esac
    if [ "$waited" -ge "$ROLLOUT_SECONDS" ]; then
      echo "Task-Liste von ${svc}:" >&2
      dk service ps "$svc" --no-trunc >&2 || true
      echo "Letzte Logzeilen:" >&2
      dk service logs --tail 40 "$svc" >&2 || true
      die "Das Rollout wurde in ${ROLLOUT_SECONDS} s nicht fertig (Update=${ustate:-keins}). Neue Tasks bleiben ungesund, solange /ready fehlschlägt (Datenbank nicht erreichbar, Pool-Zeitüberschreitungen, Schema nicht aktuell). Swarm aktualisiert weiter oder setzt selbst zurück."
    fi
    sleep 3
  done
  dk service ps "$svc" --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}\t{{.CurrentState}}'
}

# update_pinned IMAGE [--force]: after the backend, roll an active pinned service to the same image, else old and new
# versions would answer side by side behind the proxy. Absent or 0 replicas: nothing to do.
update_pinned() {
  local n
  n="$(pinned_active)"
  [ -n "$n" ] || return 0
  say "Aktualisiere auch ${PINNED} (${n} Replika(s)) auf ${1} ..."
  # shellcheck disable=SC2086
  dk service update --detach --with-registry-auth --image "$1" ${2:-} "$PINNED" >/dev/null
  watch_rollout "$PINNED"
}
# One line for --dry-run when the pinned service would follow.
pinned_plan() {
  local n
  n="$(pinned_active)"
  [ -z "$n" ] || echo "Dienst ${PINNED}: aktiv (${n} Replika(s)), würde nach ${BACKEND} ebenfalls auf ${1} umgestellt"
}

check_result() {
  if [ -n "$BASE_URL" ]; then
    say "GET ${BASE_URL%/}/ready -> $(curlb -fsS "${BASE_URL%/}/ready" 2>&1 || echo 'noch nicht bereit')"
    say "GET ${BASE_URL%/}/health -> $(curlb -fsS "${BASE_URL%/}/health" 2>&1 | head -c 300 || echo 'keine Antwort')"
  else
    say "PUBLIC_BASE_URL ist in der Env-Datei nicht gesetzt; die Bereitschaftsprüfung entfällt."
  fi
}

# Sets BACKEND_OK and MIGRATE_MISSING (read-only docker calls).
preflight_services() {
  BACKEND_OK=0; MIGRATE_MISSING=0
  if service_exists "$BACKEND"; then BACKEND_OK=1; fi
  if [ "$BACKEND_OK" = 1 ] && [ "$MIGRATE" = 1 ] && ! service_exists "$MIGRATE_SERVICE"; then MIGRATE_MISSING=1; fi
}

# ---- mode: status ------------------------------------------------------------------------------------------------------
do_status() {
  local problems=0 bak_image mig_line mig_state mig_err ustate replicas running_img pinned_img path
  say "update.sh Version ${SCRIPT_VERSION}"
  echo "Stack:            ${STACK}"
  echo "Env-Datei:        ${ENV_FILE}"
  echo "Stack-Datei:      ${STACK_FILE:-<nicht gefunden>}"
  echo "Image in .env:    ${CURRENT_IMAGE}"
  bak_image="$( [ -f "${ENV_FILE}.bak" ] && env_get "${ENV_FILE}.bak" TIMETRACK_IMAGE || true)"
  echo "Image in .bak:    ${bak_image:-<keine Sicherung>}"
  ensure_manager
  if service_exists "$BACKEND"; then
    check_stack_drift
    if [ "$DRIFT" = 1 ]; then problems=$((problems + 1)); fi
    running_img="$(svc_field "$BACKEND" '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed 's/@sha256:.*//')"
    ustate="$(svc_field "$BACKEND" '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')"
    replicas="$(svc_replicas "$BACKEND")"
    echo "Backend-Image:    ${running_img:-?}"
    echo "Backend-Replikas: ${replicas:-?}   Update-Zustand: ${ustate:-keiner}"
    if [ "$running_img" != "$CURRENT_IMAGE" ]; then echo "PROBLEM: das laufende Backend-Image weicht von der .env ab (Update unvollständig oder nicht per Skript?)"; problems=$((problems + 1)); fi
    case "$ustate" in ""|completed) ;; *) echo "PROBLEM: Rollout-Zustand '${ustate}'"; problems=$((problems + 1)) ;; esac
    case "$replicas" in */*) if [ "${replicas%%/*}" != "${replicas##*/}" ]; then echo "PROBLEM: nicht alle Replikas laufen (${replicas})"; problems=$((problems + 1)); fi ;; esac
    if [ -n "$(pinned_active)" ]; then
      pinned_img="$(svc_field "$PINNED" '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed 's/@sha256:.*//')"
      echo "Pinned-Image:    ${pinned_img:-?}   Replikas: $(svc_replicas "$PINNED")"
      if [ "$pinned_img" != "$running_img" ]; then echo "PROBLEM: ${PINNED} läuft mit einem anderen Image als ${BACKEND} (alte und neue Version antworten nebeneinander); erneut update.sh --force ausführen"; problems=$((problems + 1)); fi
    fi
  else
    echo "PROBLEM: der Dienst ${BACKEND} existiert nicht."; problems=$((problems + 1))
  fi
  if service_exists "$MIGRATE_SERVICE"; then
    mig_line="$(dk service ps "$MIGRATE_SERVICE" --no-trunc --format '{{.CurrentState}}|{{.Error}}' 2>/dev/null | head -n 1 || true)"
    mig_state="${mig_line%%|*}"; mig_err="${mig_line#*|}"
    echo "Migrationsdienst: vorhanden; letzter Task: ${mig_state:-keiner}${mig_err:+ (${mig_err})}"
    case "${mig_state%% *}" in Failed|Rejected|Orphaned) echo "PROBLEM: der letzte Migrations-Task ist fehlgeschlagen."; problems=$((problems + 1)) ;; esac
  else
    echo "PROBLEM: der Dienst ${MIGRATE_SERVICE} fehlt. Ein normaler Lauf von update.sh stellt ihn aus der Stack-Datei wieder her."; problems=$((problems + 1))
  fi
  if [ -n "$BASE_URL" ]; then
    for path in ready health; do
      if curlb -fsS -o /dev/null "${BASE_URL%/}/${path}" 2>/dev/null; then echo "GET /${path}: ok"
      else echo "PROBLEM: GET ${BASE_URL%/}/${path} antwortet nicht mit 2xx."; problems=$((problems + 1)); fi
    done
  else
    echo "PUBLIC_BASE_URL nicht gesetzt: keine Health-Prüfung."
  fi
  if [ "$problems" -eq 0 ]; then good "Ergebnis: alles in Ordnung."; else echo "Ergebnis: ${problems} Problem(e) gefunden." >&2; REPORTED=1; return 1; fi
}

# ---- mode: rollback ----------------------------------------------------------------------------------------------------
do_rollback() {
  local prev
  STEPS=5
  step "Rollback vorbereiten"
  if [ -n "$TAG" ]; then prev="${IMAGE_BASE}:${TAG}"
  else
    [ -f "${ENV_FILE}.bak" ] || die "Keine Sicherung ${ENV_FILE}.bak gefunden. Mit --tag TAG den Zielstand angeben."
    prev="$(env_get "${ENV_FILE}.bak" TIMETRACK_IMAGE)"
    [ -n "$prev" ] || die "In ${ENV_FILE}.bak ist TIMETRACK_IMAGE nicht gesetzt. Mit --tag TAG den Zielstand angeben."
  fi
  NEW_IMAGE="$prev"; OLD_IMAGE_FOR_HINT="$CURRENT_IMAGE"
  echo "Aktuell:   ${CURRENT_IMAGE}"
  echo "Zurück zu: ${prev}"
  [ "$prev" != "$CURRENT_IMAGE" ] || die "Das Zielimage entspricht dem aktuellen Stand; nichts zu tun."
  if [ "$DRY" = 1 ]; then
    if dk info >/dev/null 2>&1; then pinned_plan "$prev"; fi
    echo "Trockenlauf: würde TIMETRACK_IMAGE zurücksetzen und ${BACKEND} per Rolling Update auf ${prev} stellen (Migrationsdienst und Schema bleiben unberührt)."; return 0
  fi
  ensure_manager
  service_exists "$BACKEND" || die "Der Dienst ${BACKEND} existiert nicht."
  step "Bestätigen"
  acquire_lock
  warn "Das Datenbankschema wird NICHT zurückgesetzt. Nach einer angewendeten Migration ist der alte Stand nur sicher, wenn die Migration abwärtskompatibel war; im Zweifel das Backup einspielen."
  confirm "Backend wirklich auf ${prev} zurücksetzen?"
  HISTORY=1
  step "Image in ${ENV_FILE} zurücksetzen"; PHASE="env-file"
  write_env_image "$prev"
  step "Backend zurücksetzen (Rolling Update)"; PHASE="rollout"
  dk service update --detach --with-registry-auth --image "$prev" "$BACKEND" >/dev/null
  say "Update gestartet; beobachte das Rollout ..."
  watch_rollout
  update_pinned "$prev"
  step "Ergebnis prüfen"; PHASE="check"
  check_result
  good "Rollback fertig nach $(elapsed). Die vorherige .env steht jetzt in ${ENV_FILE}.bak (ein zweiter --rollback geht wieder vor)."
}

# ---- mode: update ------------------------------------------------------------------------------------------------------
do_update() {
  local force_flag=""
  say "update.sh Version ${SCRIPT_VERSION}"
  if [ "$SELF_CHECK" != 0 ]; then self_check_hint; fi
  step "Neuesten Image-Tag suchen und Umgebung prüfen"
  if [ -z "$TAG" ]; then find_newest_tag; else say "Verwende den Tag aus --tag: ${TAG}"; fi
  NEW_IMAGE="${IMAGE_BASE}:${TAG}"
  OLD_IMAGE_FOR_HINT="$CURRENT_IMAGE"
  echo "Stack:     ${STACK}"
  echo "Env-Datei: ${ENV_FILE}"
  echo "Aktuell:   ${CURRENT_IMAGE}"
  echo "Neu:       ${NEW_IMAGE}"
  if [ "$DRY" = 1 ]; then
    if command -v docker >/dev/null 2>&1 && dk info >/dev/null 2>&1; then
      preflight_services
      if [ "$BACKEND_OK" = 1 ]; then check_stack_drift; fi
      if [ "$BACKEND_OK" = 1 ]; then echo "Dienst ${BACKEND}: vorhanden"; else echo "PROBLEM: Dienst ${BACKEND} fehlt (Erstinstallation: docs/DEPLOYMENT.md)"; fi
      if [ "$MIGRATE_MISSING" = 1 ]; then echo "Dienst ${MIGRATE_SERVICE}: FEHLT, würde aus ${STACK_FILE:-<stack.yaml nicht gefunden>} wiederhergestellt"; fi
      if [ "$BACKEND_OK" = 1 ]; then pinned_plan "$NEW_IMAGE"; fi
    else
      echo "(docker nicht erreichbar: Dienste nicht geprüft)"
    fi
    echo "Trockenlauf: würde TIMETRACK_IMAGE setzen, ${MIGRATE_SERVICE} mit dem neuen Image ausführen, dann ${BACKEND} per Rolling Update umstellen. Es wurde nichts geändert."
    return 0
  fi
  ensure_manager
  preflight_services
  [ "$BACKEND_OK" = 1 ] || die "Der Dienst ${BACKEND} existiert nicht. Das ist eine Erstinstallation: docs/DEPLOYMENT.md, Abschnitt 'Erstes Deployment'."
  if [ "$MIGRATE_MISSING" = 1 ]; then
    warn "Der Dienst ${MIGRATE_SERVICE} fehlt; er wird in Schritt 4 aus der Stack-Datei wiederhergestellt."
    [ -n "$STACK_FILE" ] && [ -f "$STACK_FILE" ] || die "Der Dienst ${MIGRATE_SERVICE} fehlt, aber die Stack-Datei wurde nicht gefunden. stack.yaml neben update.sh legen (Branch deploy) oder --stack-file angeben."
  fi

  check_stack_drift
  [ "$MISSING_SECRETS" = 0 ] || die "Secrets fehlen: zuerst create-secrets.sh --add-only ausführen."
  if [ "$DRIFT" = 1 ] && [ "$APPLY_DRIFT" = 0 ]; then
    die "Konfigurationsdrift erkannt. Stack und Overlays prüfen, dann mit --apply-stack-drift erneut starten (Stack-Deploy kann alle Dienste ändern)."
  fi
  if [ "$NEW_IMAGE" = "$CURRENT_IMAGE" ] && [ "$FORCE" = 0 ] && [ "$DRIFT" = 0 ]; then
    good "Bereits auf dem neuesten Stand. Nichts zu tun (--force startet trotzdem neu)."
    return 0
  fi

  step "Bestätigen"
  acquire_lock
  confirm "Datenbank gesichert? Mit dem Update fortfahren?"
  HISTORY=1

  step "Neues Image in ${ENV_FILE} eintragen"; PHASE="env-file"
  write_env_image "$NEW_IMAGE"

  if [ "$MIGRATE" = 1 ]; then
    step "Datenbankmigration ausführen (Job ${MIGRATE_SERVICE})"; PHASE="migration"
    if [ -n "${UPDATE_BACKUP_CMD:-}" ]; then
      say "Führe UPDATE_BACKUP_CMD vor der Migration aus ..."
      bash -c "$UPDATE_BACKUP_CMD" || die "UPDATE_BACKUP_CMD ist fehlgeschlagen; es wurde nicht migriert. Das Backend ist unverändert."
    fi
    if [ "$MIGRATE_MISSING" = 1 ]; then restore_migrate_service
    elif [ "$DRIFT" = 1 ]; then deploy_current_stack; fi
    run_migration
  else
    step "Datenbankmigration"
    say "Übersprungen (--skip-migrate)."
    if [ "$DRIFT" = 1 ]; then deploy_current_stack; fi
  fi

  step "Backend aktualisieren (Rolling Update, ein Replikat nach dem anderen)"; PHASE="rollout"
  if [ "$FORCE" = 1 ]; then force_flag="--force"; fi
  # shellcheck disable=SC2086
  dk service update --detach --with-registry-auth --image "$NEW_IMAGE" $force_flag "$BACKEND" >/dev/null
  say "Update gestartet; beobachte das Rollout ..."
  watch_rollout
  update_pinned "$NEW_IMAGE" "$force_flag"

  step "Ergebnis prüfen"; PHASE="check"
  check_result
  good "Fertig nach $(elapsed). Zeigt die App einmal eine weiße Seite, die Websitedaten der Domain im Browser löschen."
}

case "$MODE" in
  self-update) do_self_update ;;
  status) do_status ;;
  rollback) do_rollback ;;
  update) do_update ;;
esac
# END update.sh
