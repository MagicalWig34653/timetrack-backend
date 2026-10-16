# shellcheck shell=bash
# Shared helpers for scripts/backup.sh, scripts/restore.sh and scripts/test-restore.sh.
# Sourced, never executed. Secrets are never printed and never written into backup artifacts:
#  - MariaDB container mode reads the root password inside the container (MARIADB_ROOT_PASSWORD);
#  - MariaDB host mode takes DB_PASSWORD / DB_PASSWORD_FILE from the environment and hands it to the
#    client only through the MYSQL_PWD variable of the child process (not via argv).

tt_log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
tt_die() { tt_log "ERROR: $*"; exit 1; }

tt_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Verifies a "<hash>  <name>" list in the given directory.
tt_sha256_check() {
  local dir="$1" list="$2"
  if command -v sha256sum >/dev/null 2>&1; then (cd "$dir" && sha256sum --quiet -c "$list")
  else (cd "$dir" && shasum -a 256 -c "$list" >/dev/null); fi
}

# tt_manifest_get FILE KEY -> value of a flat key=value line (the manifest is never sourced or evaluated).
tt_manifest_get() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

# Rejects values that would break the single-quoted SQL/CLI fragments built below.
tt_safe_ident() { case "$1" in *[!A-Za-z0-9_.-]*|'') tt_die "unsafe identifier: $1" ;; esac; }
tt_safe_path() { case "$1" in *\'*|*\"*|*$'\n'*|*\\*|'') tt_die "unsafe path (quotes, backslash or newline): $1" ;; esac; }

# --- MariaDB access --------------------------------------------------------------------------------------------
# Globals set by the caller: TT_DB_CONTAINER (container mode) or DB_HOST/DB_PORT/DB_USER (host mode).
TT_DB_CONTAINER="${TT_DB_CONTAINER:-}"
TT_DB_PW=""

tt_db_init_host_password() {
  if [ -n "${DB_PASSWORD_FILE:-}" ]; then TT_DB_PW="$(cat "$DB_PASSWORD_FILE")"
  else TT_DB_PW="${DB_PASSWORD:-}"; fi
}

# tt_db_client <tool> [args...]: tool is mariadb or mariadb-dump; stdin is passed through.
tt_db_client() {
  local tool="$1"; shift
  if [ -n "$TT_DB_CONTAINER" ]; then
    docker exec -i "$TT_DB_CONTAINER" sh -c 'tool="$1"; shift; exec "$tool" -uroot -p"$MARIADB_ROOT_PASSWORD" --default-character-set=utf8mb4 "$@"' sh "$tool" "$@"
  else
    command -v "$tool" >/dev/null 2>&1 || tt_die "$tool not found on PATH (use --db-container or install the MariaDB client)"
    MYSQL_PWD="$TT_DB_PW" "$tool" -h "${DB_HOST:-127.0.0.1}" -P "${DB_PORT:-3306}" -u "${DB_USER:-timetrack}" --default-character-set=utf8mb4 "$@"
  fi
}
tt_mysql() { tt_db_client mariadb "$@"; }
# Scalar/rows without headers: tt_mysql_q "SQL" [db]
# stdin is closed so that the call can sit inside "while read" loops without swallowing their input.
tt_mysql_q() { local sql="$1" db="${2:-}"; if [ -n "$db" ]; then tt_db_client mariadb -N -B "$db" -e "$sql" </dev/null; else tt_db_client mariadb -N -B -e "$sql" </dev/null; fi; }

# --- SQLite access ---------------------------------------------------------------------------------------------
tt_sqlite_q() { sqlite3 -batch -noheader "$1" "$2"; }

# --- Table counts and migrations (driver independent) ----------------------------------------------------------
# tt_row_counts <driver> <db-or-file> -> "table<TAB>count" sorted, one line per user table.
tt_row_counts() {
  local driver="$1" target="$2" t
  if [ "$driver" = mariadb ]; then
    tt_mysql_q "SELECT table_name FROM information_schema.tables WHERE table_schema='$target' AND table_type='BASE TABLE' ORDER BY table_name" |
      while IFS= read -r t; do printf '%s\t%s\n' "$t" "$(tt_mysql_q "SELECT COUNT(*) FROM \`$t\`" "$target")"; done
  else
    tt_sqlite_q "$target" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name" |
      while IFS= read -r t; do printf '%s\t%s\n' "$t" "$(tt_sqlite_q "$target" "SELECT COUNT(*) FROM \"$t\"")"; done
  fi
}

# tt_migrations <driver> <db-or-file> -> sorted list of applied Fluent migration names.
tt_migrations() {
  local driver="$1" target="$2"
  if [ "$driver" = mariadb ]; then tt_mysql_q "SELECT name FROM _fluent_migrations ORDER BY name" "$target"
  else tt_sqlite_q "$target" "SELECT name FROM _fluent_migrations ORDER BY name"; fi
}
