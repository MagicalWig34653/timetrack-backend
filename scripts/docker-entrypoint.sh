#!/bin/sh
# Container entrypoint: Docker/Swarm secrets convention. For every allow-listed variable VAR, a variable VAR_FILE
# pointing at a file (for example /run/secrets/tt_db_password) is read into VAR before the backend starts.
# The backend itself only reads plain environment variables (docs/BETRIEB.md, "Secrets"). Values are never printed.
# Setting both VAR and VAR_FILE is an error (no silent precedence).
set -eu

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
  export "$name=$value"
  unset "$file_var"
done

exec /app/App "$@"
