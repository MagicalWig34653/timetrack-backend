#!/usr/bin/env bash
# Timetrack restore from a directory written by scripts/backup.sh.
# Verifies the manifest and checksums first, refuses to touch a non-empty target without --force-overwrite,
# restores database and local files together and verifies the result. Stop the backend before restoring.
# Procedure: docs/BETRIEB.md.
#
#   scripts/restore.sh --from DIR --sqlite-path /data/timetrack.sqlite --files-target /data/files
#   scripts/restore.sh --from DIR --db-container timetrack-dev-db-1 --db-name timetrack
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/backup-common.sh
. "$ROOT/scripts/lib/backup-common.sh"

FROM=""
SQLITE_PATH_ARG=""
DB_NAME_ARG=""
FILES_TARGET=""
FORCE=0
STRICT_COUNTS=0

usage() {
  cat <<'USAGE'
Usage: scripts/restore.sh --from BACKUP_DIR [options]
  --sqlite-path FILE      target SQLite file (driver sqlite)
  --db-container NAME     MariaDB container (client runs inside, root password from the container environment)
  --db-name NAME          target database (default: the name stored in the manifest)
  --files-target DIR      restore local files here (default: local_root from the manifest). The backend binds each
                          file to the real path it was written to, so the path must normally be identical.
  --force-overwrite       replace a non-empty target: MariaDB DROP DATABASE; SQLite file and files directory are
                          renamed to *.pre-restore-<UTC> (never deleted)
  --strict-counts         fail (instead of warn) if table row counts differ from the manifest
Host mode for MariaDB (no --db-container): DB_HOST, DB_PORT, DB_USER and DB_PASSWORD or DB_PASSWORD_FILE from the environment.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --sqlite-path) SQLITE_PATH_ARG="$2"; shift 2 ;;
    --db-container) TT_DB_CONTAINER="$2"; shift 2 ;;
    --db-name) DB_NAME_ARG="$2"; shift 2 ;;
    --files-target) FILES_TARGET="$2"; shift 2 ;;
    --force-overwrite) FORCE=1; shift ;;
    --strict-counts) STRICT_COUNTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; tt_die "unknown option: $1" ;;
  esac
done

[ -n "$FROM" ] && [ -d "$FROM" ] || { usage >&2; tt_die "--from must be a backup directory"; }
FROM="$(cd "$FROM" && pwd -P)"
M="$FROM/MANIFEST"

# 1. Manifest and checksums: nothing is touched before this passes
[ -f "$M" ] && [ -f "$FROM/SHA256SUMS" ] || tt_die "MANIFEST or SHA256SUMS missing: not a backup directory"
tt_sha256_check "$FROM" SHA256SUMS || tt_die "checksum verification failed: backup is damaged or was modified"
[ "$(tt_manifest_get "$M" format)" = 1 ] || tt_die "unsupported manifest format: $(tt_manifest_get "$M" format)"
DRIVER="$(tt_manifest_get "$M" driver)"
ARTIFACT_DB="$(tt_manifest_get "$M" artifact_db)"
ARTIFACT_FILES="$(tt_manifest_get "$M" artifact_files)"
LOCAL_ROOT="$(tt_manifest_get "$M" local_root)"
[ "$(tt_sha256 "$FROM/migrations.txt")" = "$(tt_manifest_get "$M" migrations_sha256)" ] || tt_die "migration list does not match the manifest"
tt_log "backup ok: driver=$DRIVER created=$(tt_manifest_get "$M" created_utc) migrations=$(tt_manifest_get "$M" migrations_count)"

# 2. Preflight of all targets (still read-only)
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
case "$DRIVER" in
  sqlite)
    [ -n "$SQLITE_PATH_ARG" ] || tt_die "--sqlite-path is required for a sqlite backup"
    tt_safe_path "$SQLITE_PATH_ARG"
    command -v sqlite3 >/dev/null 2>&1 || tt_die "sqlite3 CLI not found"
    if [ -s "$SQLITE_PATH_ARG" ] && [ "$FORCE" -ne 1 ]; then tt_die "target $SQLITE_PATH_ARG exists and is not empty (use --force-overwrite)"; fi
    ;;
  mariadb)
    [ -n "$DB_NAME_ARG" ] || DB_NAME_ARG="$(tt_manifest_get "$M" db_name)"
    tt_safe_ident "$DB_NAME_ARG"
    [ -n "$TT_DB_CONTAINER" ] || tt_db_init_host_password
    EXISTING="$(tt_mysql_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME_ARG'")"
    if [ "$EXISTING" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
      tt_die "database $DB_NAME_ARG already has $EXISTING table(s) (use --force-overwrite to drop and recreate it)"
    fi
    ;;
  *) tt_die "unknown driver in manifest: $DRIVER" ;;
esac
if [ -n "$ARTIFACT_FILES" ]; then
  [ -n "$FILES_TARGET" ] || FILES_TARGET="$LOCAL_ROOT"
  [ -n "$FILES_TARGET" ] || tt_die "no --files-target given and the manifest has no local_root"
  tt_safe_path "$FILES_TARGET"
  if [ "$FILES_TARGET" != "$LOCAL_ROOT" ]; then
    tt_log "WARNING: files target differs from the original root ($LOCAL_ROOT). Local files stay unreadable until stored_files rows are rebound (docs/BETRIEB.md)."
  fi
  if [ -d "$FILES_TARGET" ] && [ -n "$(ls -A "$FILES_TARGET")" ] && [ "$FORCE" -ne 1 ]; then
    tt_die "files target $FILES_TARGET is not empty (use --force-overwrite)"
  fi
fi

# 3. Database
if [ "$DRIVER" = sqlite ]; then
  if [ -e "$SQLITE_PATH_ARG" ]; then
    mv "$SQLITE_PATH_ARG" "$SQLITE_PATH_ARG.pre-restore-$STAMP"
    for ext in -wal -shm; do
      if [ -e "$SQLITE_PATH_ARG$ext" ]; then mv "$SQLITE_PATH_ARG$ext" "$SQLITE_PATH_ARG$ext.pre-restore-$STAMP"; fi
    done
  fi
  mkdir -p "$(dirname "$SQLITE_PATH_ARG")"
  TMP="$SQLITE_PATH_ARG.restore-tmp"
  gzip -dc "$FROM/$ARTIFACT_DB" >"$TMP"
  [ "$(tt_sqlite_q "$TMP" 'PRAGMA integrity_check')" = ok ] || { rm -f "$TMP"; tt_die "restored SQLite file fails integrity_check"; }
  mv "$TMP" "$SQLITE_PATH_ARG"
  DBREF="$SQLITE_PATH_ARG"
else
  if [ "$EXISTING" -gt 0 ]; then
    tt_log "dropping database $DB_NAME_ARG (--force-overwrite)"
    tt_mysql_q "DROP DATABASE \`$DB_NAME_ARG\`" || tt_die "drop failed"
  fi
  tt_mysql_q "CREATE DATABASE IF NOT EXISTS \`$DB_NAME_ARG\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  tt_log "loading dump into $DB_NAME_ARG"
  gzip -dc "$FROM/$ARTIFACT_DB" | tt_mysql "$DB_NAME_ARG"
  DBREF="$DB_NAME_ARG"
fi

# 4. Files
if [ -n "$ARTIFACT_FILES" ]; then
  if [ -d "$FILES_TARGET" ] && [ -n "$(ls -A "$FILES_TARGET")" ]; then mv "$FILES_TARGET" "$FILES_TARGET.pre-restore-$STAMP"; fi
  mkdir -p "$FILES_TARGET"
  chmod 700 "$FILES_TARGET"
  tar -xzf "$FROM/$ARTIFACT_FILES" -C "$FILES_TARGET"
fi

# 5. Verification against the manifest
FAIL=0
if [ "$(tt_migrations "$DRIVER" "$DBREF")" != "$(cat "$FROM/migrations.txt")" ]; then tt_log "MISMATCH: migration list differs"; FAIL=1; fi
tt_row_counts "$DRIVER" "$DBREF" >"$FROM/.restored_counts.$$"
if ! diff -q "$FROM/row_counts.tsv" "$FROM/.restored_counts.$$" >/dev/null; then
  tt_log "row counts differ from the manifest (tables: $(diff "$FROM/row_counts.tsv" "$FROM/.restored_counts.$$" | grep -c '^>' || true))"
  if [ "$STRICT_COUNTS" -eq 1 ]; then FAIL=1; fi
fi
rm -f "$FROM/.restored_counts.$$"
if [ -n "$ARTIFACT_FILES" ]; then
  if ! (cd "$FILES_TARGET" && if command -v sha256sum >/dev/null 2>&1; then sha256sum --quiet -c "$FROM/files.sha256"; else shasum -a 256 -c "$FROM/files.sha256" >/dev/null; fi); then
    tt_log "MISMATCH: restored file checksums differ"; FAIL=1
  fi
fi
[ "$FAIL" -eq 0 ] || tt_die "restore finished but verification failed; do not start the backend on this data"
tt_log "restore verified: migrations, checksums$([ "$STRICT_COUNTS" -eq 1 ] && echo ', row counts') ok"
tt_log "next: start the backend with the ORIGINAL STORAGE_SECRET_KEY and VAPID keys (not part of the backup)"
