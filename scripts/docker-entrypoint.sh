#!/bin/sh
# Container entrypoint: Docker/Swarm secrets convention. For every allow-listed variable VAR, a variable VAR_FILE
# pointing at a file (for example /run/secrets/tt_db_password) is read into VAR before the backend starts.
# The backend itself only reads plain environment variables (docs/BETRIEB.md, "Secrets"). Values are never printed.
# Setting both VAR and VAR_FILE is an error (no silent precedence).
# Placeholder secrets: Docker secrets cannot be empty, so deploy/swarm/create-secrets.sh creates the secrets of optional
# features with the content below. A file that is empty or holds only this marker means "not configured": VAR stays unset.
# (Keep in sync with EnvironmentSanitizer.placeholderMarker in the backend and PLACEHOLDER in create-secrets.sh.)
set -eu
PLACEHOLDER="TIMETRACK_PLACEHOLDER_UNSET"

for name in DB_PASSWORD STORAGE_SECRET_KEY VAPID_PRIVATE_KEY APNS_PRIVATE_KEY SMTP_PASSWORD OIDC_CLIENT_SECRET; do
  file_var="${name}_FILE"
  eval "file=\${$file_var:-}"
  [ -n "$file" ] || continue
  eval "current=\${$name:-}"
  if [ -n "$current" ]; then
    echo "docker-entrypoint: both $name and $file_var are set; refusing to choose" >&2
    exit 64
  fi
  if [ ! -r "$file" ]; then
    echo "docker-entrypoint: $file_var points to an unreadable file" >&2
    exit 66
  fi
  # $(cat) strips trailing newlines, which is what secret files usually contain.
  value="$(cat "$file")"
  unset "$file_var"
  # Compare without surrounding whitespace; an empty or placeholder file leaves the variable unset.
  trimmed="$(printf '%s' "$value" | tr -d '[:space:]')"
  if [ -z "$trimmed" ] || [ "$trimmed" = "$PLACEHOLDER" ]; then
    echo "docker-entrypoint: $name: secret is a placeholder (feature not configured)" >&2
    continue
  fi
  export "$name=$value"
done

exec /app/App "$@"
