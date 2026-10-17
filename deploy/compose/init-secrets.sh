#!/usr/bin/env bash
# Creates ./secrets/ for the Compose setup: database password (asked, or generated), storage key, VAPID key.
# Values are never printed. Existing files are never overwritten. Usage: ./init-secrets.sh [--generate-db-password]
set -euo pipefail
cd "$(dirname "$0")"
umask 077
mkdir -p secrets
chmod 700 secrets
put() { # put NAME  (value from stdin)
  [ ! -e "secrets/$1" ] || { echo "secrets/$1 exists - not overwritten" >&2; return 0; }
  cat > "secrets/$1"
  # The container user (uid 10001) reads the bind-mounted file: it must be world-readable, so the directory stays 0700.
  chmod 644 "secrets/$1"
}
if [ ! -e secrets/tt_db_password ]; then
  if [ "${1:-}" = "--generate-db-password" ]; then
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' | put tt_db_password
    echo "Database password generated in secrets/tt_db_password (use it for CREATE USER / the bundled db)."
  else
    read -r -s -p "Password of the MariaDB user (input hidden): " pw; echo
    [ -n "$pw" ] || { echo "empty password" >&2; exit 1; }
    printf '%s' "$pw" | put tt_db_password
  fi
fi
[ -e secrets/tt_storage_secret_key ] || openssl rand -base64 32 | tr -d '\n' | put tt_storage_secret_key
# SEC1 DER of a prime256v1 key: 7 bytes header, then the 32-byte private scalar (same pipeline as deploy/swarm/create-secrets.sh)
gen_vapid_key() {
  openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl ec -outform DER 2>/dev/null \
    | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'
}
[ -e secrets/tt_vapid_private_key ] || gen_vapid_key | put tt_vapid_private_key
echo "Done. BACK UP secrets/tt_storage_secret_key and secrets/tt_vapid_private_key: without the storage key, stored S3 credentials are unrecoverable."
