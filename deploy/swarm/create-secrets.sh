#!/usr/bin/env bash
# Creates the Docker secrets of the Timetrack Swarm stack (deploy/swarm/stack.yaml).
#
#   deploy/swarm/create-secrets.sh [--dry-run] [--db-password-file FILE | --generate-db-password FILE]
#                                  [--save-generated DIR] [--smtp-password-file FILE] [--oidc-client-secret-file FILE]
#                                  [--apns-private-key-file FILE] [--add-only] [--prefix tt_]
#
# Secrets:
#   tt_db_password          the password of the MariaDB user. Either read from --db-password-file, or generated with
#                           --generate-db-password FILE (the value is written ONLY to that file, mode 0600, so you can
#                           use it in CREATE USER; delete the file afterwards). Without both options the script asks
#                           for it on the terminal (no echo).
#   tt_storage_secret_key   base64 of 32 random bytes (AES-256-GCM key for stored S3 credentials). Generated here.
#   tt_vapid_private_key    P-256 private key, 32 bytes, base64url without padding (Web Push). Generated here; the
#                           backend has no command for it, so the documented openssl pipeline is used.
#   (--save-generated DIR writes the generated storage key and VAPID key to DIR/tt_storage_secret_key and
#   DIR/tt_vapid_private_key, mode 0600, so you can put them into a password manager. Docker never shows a secret
#   value again. Without this option the generated values are unrecoverable. DIR must not contain these files yet.)
#   tt_smtp_password        only with --smtp-password-file (or --smtp-password-stdin)
#   tt_oidc_client_secret   only with --oidc-client-secret-file
#   tt_apns_private_key     only with --apns-private-key-file: the Apple .p8 APNs key (PEM, EC P-256). The file is
#                           validated with openssl without printing it; the PEM text (with line breaks) becomes the
#                           secret value. Needs the APNs block in stack.yaml (docs/DEPLOYMENT.md).
#
# --add-only: for an existing stack. Skips tt_db_password, tt_storage_secret_key and tt_vapid_private_key (which must
#   stay as they are) and creates only the optional secrets given by --smtp-password-file, --oidc-client-secret-file and
#   --apns-private-key-file, e.g. to add APNs later.
#
# Guarantees: values are never printed and never passed as command-line arguments (they travel through stdin and
# files with mode 0600); existing secrets are never overwritten (the script aborts before creating anything).
# --dry-run generates and validates every value in memory, checks which secrets exist (if Swarm is reachable) and
# creates nothing, writes nothing.
set -euo pipefail
umask 077

DRY_RUN=0
PREFIX="tt_"
DB_PASSWORD_FILE=""
GENERATE_DB_PASSWORD_FILE=""
SMTP_PASSWORD_FILE=""
OIDC_SECRET_FILE=""
APNS_KEY_FILE=""
SAVE_DIR=""
ADD_ONLY=0

die() { echo "create-secrets: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --add-only) ADD_ONLY=1 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; shift ;;
    --db-password-file) [ $# -ge 2 ] || die "--db-password-file needs a path"; DB_PASSWORD_FILE="$2"; shift ;;
    --generate-db-password) [ $# -ge 2 ] || die "--generate-db-password needs a path"; GENERATE_DB_PASSWORD_FILE="$2"; shift ;;
    --smtp-password-file) [ $# -ge 2 ] || die "--smtp-password-file needs a path"; SMTP_PASSWORD_FILE="$2"; shift ;;
    --oidc-client-secret-file) [ $# -ge 2 ] || die "--oidc-client-secret-file needs a path"; OIDC_SECRET_FILE="$2"; shift ;;
    --apns-private-key-file) [ $# -ge 2 ] || die "--apns-private-key-file needs a path"; APNS_KEY_FILE="$2"; shift ;;
    --save-generated) [ $# -ge 2 ] || die "--save-generated needs a directory"; SAVE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

if [ "$ADD_ONLY" -eq 1 ]; then
  [ -z "$DB_PASSWORD_FILE$GENERATE_DB_PASSWORD_FILE$SAVE_DIR" ] || die "--add-only cannot be combined with the database password or --save-generated options"
  [ -n "$SMTP_PASSWORD_FILE$OIDC_SECRET_FILE$APNS_KEY_FILE" ] || die "--add-only needs at least one of --smtp-password-file, --oidc-client-secret-file, --apns-private-key-file"
fi
[ -z "$DB_PASSWORD_FILE" ] || [ -z "$GENERATE_DB_PASSWORD_FILE" ] || die "use either --db-password-file or --generate-db-password"
case "$PREFIX" in *[!a-zA-Z0-9_.-]*|"") die "--prefix may only contain letters, digits, _ . -" ;; esac
command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v docker >/dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] || die "docker is required"

for f in "$DB_PASSWORD_FILE" "$SMTP_PASSWORD_FILE" "$OIDC_SECRET_FILE" "$APNS_KEY_FILE"; do
  [ -z "$f" ] || [ -r "$f" ] || die "cannot read $f"
done
if [ -n "$SAVE_DIR" ]; then
  [ -d "$SAVE_DIR" ] || die "--save-generated: $SAVE_DIR is not a directory"
  for n in "${PREFIX}storage_secret_key" "${PREFIX}vapid_private_key"; do
    [ ! -e "$SAVE_DIR/$n" ] || die "$SAVE_DIR/$n already exists; refusing to overwrite"
  done
fi
if [ -n "$GENERATE_DB_PASSWORD_FILE" ] && [ -e "$GENERATE_DB_PASSWORD_FILE" ]; then
  die "$GENERATE_DB_PASSWORD_FILE already exists; choose another path"
fi

# ---- value generators (print to stdout, never to the terminal unless captured) ----
gen_storage_key() { openssl rand -base64 32 | tr -d '\n'; }
# SEC1 DER of a prime256v1 key: 7 bytes header, then the 32-byte private scalar.
gen_vapid_key() {
  openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl ec -outform DER 2>/dev/null \
    | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'
}
# 32 random bytes, base64url: 43 characters of a-z A-Z 0-9 - _ (safe in SQL strings and shells).
gen_password() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'; }

# ---- collect values into memory ----
ORDER=()
V_db=""; V_storage=""; V_vapid=""; V_smtp=""; V_oidc=""; V_apns=""
value_of() { local v="V_$1"; printf '%s' "${!v}"; }

if [ "$ADD_ONLY" -eq 0 ]; then
V_storage="$(gen_storage_key)"
[ "$(printf '%s' "$V_storage" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "32" ] || die "storage key generation failed"
ORDER+=(storage)

V_vapid="$(gen_vapid_key)"
# 32 bytes base64url without padding = 43 characters
[ "${#V_vapid}" -eq 43 ] || die "VAPID key generation failed (openssl output unexpected; ${#V_vapid} characters)"
ORDER+=(vapid)

if [ -n "$DB_PASSWORD_FILE" ]; then
  V_db="$(cat "$DB_PASSWORD_FILE")"
elif [ -n "$GENERATE_DB_PASSWORD_FILE" ]; then
  V_db="$(gen_password)"
elif [ "$DRY_RUN" -eq 1 ]; then
  V_db="dry-run-placeholder"
else
  [ -t 0 ] || die "no terminal for the database password prompt; use --db-password-file or --generate-db-password"
  printf 'Database password (input hidden): ' >&2
  IFS= read -rs pw; echo >&2
  printf 'Repeat: ' >&2
  IFS= read -rs pw2; echo >&2
  [ "$pw" = "$pw2" ] || die "passwords differ"
  V_db="$pw"; unset pw pw2
fi
[ -n "$V_db" ] || die "the database password is empty"
ORDER+=(db)
fi

if [ -n "$SMTP_PASSWORD_FILE" ]; then V_smtp="$(cat "$SMTP_PASSWORD_FILE")"; [ -n "$V_smtp" ] || die "SMTP password file is empty"; ORDER+=(smtp); fi
if [ -n "$OIDC_SECRET_FILE" ]; then V_oidc="$(cat "$OIDC_SECRET_FILE")"; [ -n "$V_oidc" ] || die "OIDC secret file is empty"; ORDER+=(oidc); fi
if [ -n "$APNS_KEY_FILE" ]; then
  # Validate without printing: must be an unencrypted PEM private key that is an EC key on prime256v1 (P-256), as Apple issues.
  # openssl output is captured/discarded; the key text never reaches the terminal.
  grep -q -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$APNS_KEY_FILE" 2>/dev/null || die "--apns-private-key-file: not a PEM private key (expected the Apple .p8 file)"
  if grep -q -e 'BEGIN ENCRYPTED PRIVATE KEY' "$APNS_KEY_FILE" 2>/dev/null; then die "--apns-private-key-file: the key is encrypted; APNs .p8 files are not"; fi
  apns_info="$(openssl pkey -in "$APNS_KEY_FILE" -noout -text </dev/null 2>/dev/null)" || die "--apns-private-key-file: openssl cannot parse the key"
  printf '%s' "$apns_info" | grep -q 'prime256v1' || die "--apns-private-key-file: not an EC P-256 (prime256v1) private key"
  unset apns_info
  # shellcheck disable=SC2034 # read indirectly by value_of
  V_apns="$(cat "$APNS_KEY_FILE")"
  ORDER+=(apns)
fi

name_of() {
  case "$1" in
    db) echo "${PREFIX}db_password" ;;
    storage) echo "${PREFIX}storage_secret_key" ;;
    vapid) echo "${PREFIX}vapid_private_key" ;;
    smtp) echo "${PREFIX}smtp_password" ;;
    oidc) echo "${PREFIX}oidc_client_secret" ;;
    apns) echo "${PREFIX}apns_private_key" ;;
  esac
}

# ---- existence check (before anything is created) ----
SWARM_OK=0
if command -v docker >/dev/null 2>&1 && [ "$(docker info --format '{{.Swarm.LocalNodeState}}/{{.Swarm.ControlAvailable}}' 2>/dev/null || true)" = "active/true" ]; then
  SWARM_OK=1
fi
if [ "$SWARM_OK" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  die "this node is not a Swarm manager (docker info: Swarm LocalNodeState/ControlAvailable != active/true)"
fi

existing=()
if [ "$SWARM_OK" -eq 1 ]; then
  for key in "${ORDER[@]}"; do
    if docker secret inspect "$(name_of "$key")" >/dev/null 2>&1; then existing+=("$(name_of "$key")"); fi
  done
fi
if [ "${#existing[@]}" -gt 0 ]; then
  die "refusing to overwrite existing secrets: ${existing[*]} (Docker secrets are immutable: create new ones with another --prefix and adapt stack.yaml, or remove them yourself first)"
fi

# ---- create ----
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: nothing is created or written."
  [ "$SWARM_OK" -eq 1 ] || echo "(Swarm manager not reachable: existence of secrets not checked.)"
  for key in "${ORDER[@]}"; do echo "would create secret: $(name_of "$key") ($(value_of "$key" | wc -c | tr -d ' ') characters)"; done
  [ -z "$SAVE_DIR" ] || echo "would write the generated storage key and VAPID key to: $SAVE_DIR (mode 0600)"
  [ -z "$GENERATE_DB_PASSWORD_FILE" ] || echo "would write the generated database password to: $GENERATE_DB_PASSWORD_FILE (mode 0600)"
  exit 0
fi

if [ -n "$GENERATE_DB_PASSWORD_FILE" ]; then
  printf '%s' "$V_db" > "$GENERATE_DB_PASSWORD_FILE"
  chmod 600 "$GENERATE_DB_PASSWORD_FILE"
fi
if [ -n "$SAVE_DIR" ]; then
  printf '%s' "$V_storage" > "$SAVE_DIR/$(name_of storage)"
  printf '%s' "$V_vapid" > "$SAVE_DIR/$(name_of vapid)"
  chmod 600 "$SAVE_DIR/$(name_of storage)" "$SAVE_DIR/$(name_of vapid)"
fi

for key in "${ORDER[@]}"; do
  value_of "$key" | docker secret create "$(name_of "$key")" - >/dev/null
  echo "created secret: $(name_of "$key")"
done
[ -z "$GENERATE_DB_PASSWORD_FILE" ] || echo "database password written to $GENERATE_DB_PASSWORD_FILE (mode 0600): use it for CREATE USER, store it in your password manager, then delete the file."
[ -n "$SAVE_DIR" ] && echo "generated keys saved to $SAVE_DIR (mode 0600): move them into a password manager and delete them from disk." || echo "WARNING: without --save-generated the storage key and VAPID key can no longer be read back (Docker never shows secret values). Losing STORAGE_SECRET_KEY makes stored S3 credentials unrecoverable (docs/BETRIEB.md section 1)."
