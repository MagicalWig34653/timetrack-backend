#!/usr/bin/env bash
# Timetrack backup: database + local file storage + manifest with checksums.
# Procedure and caveats (secrets, S3, consistency): docs/BETRIEB.md. Secrets are never written to the backup.
#
#   scripts/backup.sh --driver sqlite  --sqlite-path /data/timetrack.sqlite --local-files /data/files --out /backups
#   scripts/backup.sh --driver mariadb --db-container timetrack-dev-db-1 --db-name timetrack --out /backups
#   scripts/backup.sh --driver mariadb --db-name timetrack --out /backups     # host mode: DB_HOST/DB_PORT/DB_USER + DB_PASSWORD(_FILE)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/backup-common.sh
. "$ROOT/scripts/lib/backup-common.sh"

DRIVER="${DATABASE_DRIVER:-}"
SQLITE_PATH_ARG="${SQLITE_PATH:-}"
DB_NAME_ARG="${DB_NAME:-timetrack}"
LOCAL_FILES=""
OUT=""
ALLOW_INCONSISTENT=0

usage() {
  cat <<'USAGE'
Usage: scripts/backup.sh --out DIR [options]
  --driver mariadb|sqlite   default: $DATABASE_DRIVER
  --sqlite-path FILE        SQLite database file (online backup via the SQLite backup API)
  --db-container NAME       run mariadb-dump inside this container (reads MARIADB_ROOT_PASSWORD there)
  --db-name NAME            MariaDB database name (default: $DB_NAME or timetrack)
  --local-files DIR         local file storage root (storage rule "local"); tar'ed if given
  --allow-inconsistent      do not fail if a stored local file row has no file in the archive
  --out DIR                 parent directory; a timetrack-backup-<UTC> directory is created in it
Host mode for MariaDB (no --db-container): DB_HOST, DB_PORT, DB_USER and DB_PASSWORD or DB_PASSWORD_FILE from the environment.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --driver) DRIVER="$2"; shift 2 ;;
    --sqlite-path) SQLITE_PATH_ARG="$2"; shift 2 ;;
    --db-container) TT_DB_CONTAINER="$2"; shift 2 ;;
    --db-name) DB_NAME_ARG="$2"; shift 2 ;;
    --local-files) LOCAL_FILES="$2"; shift 2 ;;
    --allow-inconsistent) ALLOW_INCONSISTENT=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; tt_die "unknown option: $1" ;;
  esac
done

[ -n "$OUT" ] || { usage >&2; tt_die "--out is required"; }
case "$DRIVER" in mariadb|sqlite) ;; *) tt_die "--driver must be mariadb or sqlite" ;; esac
tt_safe_path "$OUT"
if [ "$DRIVER" = mariadb ]; then
  tt_safe_ident "$DB_NAME_ARG"
  [ -n "$TT_DB_CONTAINER" ] || tt_db_init_host_password
else
  [ -n "$SQLITE_PATH_ARG" ] || tt_die "--sqlite-path is required for sqlite"
  tt_safe_path "$SQLITE_PATH_ARG"
  [ -f "$SQLITE_PATH_ARG" ] || tt_die "SQLite file not found: $SQLITE_PATH_ARG"
  command -v sqlite3 >/dev/null 2>&1 || tt_die "sqlite3 CLI not found"
fi
if [ -n "$LOCAL_FILES" ]; then
  tt_safe_path "$LOCAL_FILES"
  [ -d "$LOCAL_FILES" ] || tt_die "local file root not found: $LOCAL_FILES"
  LOCAL_FILES="$(cd "$LOCAL_FILES" && pwd -P)"   # the backend binds files to the real path (storage_location)
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
DEST="$(cd "$OUT" && pwd -P)/timetrack-backup-$STAMP"
mkdir "$DEST"
on_exit() { local rc=$?; if [ "$rc" -ne 0 ]; then tt_log "backup failed (exit $rc); incomplete directory kept for inspection: $DEST"; fi; }
trap on_exit EXIT

# 1. Database (always first: rows may reference files, never the other way round)
if [ "$DRIVER" = sqlite ]; then
  SNAP="$DEST/db.sqlite"
  tt_log "SQLite online backup of $SQLITE_PATH_ARG"
  sqlite3 -batch "$SQLITE_PATH_ARG" ".timeout 10000" ".backup '$SNAP'"
  [ "$(tt_sqlite_q "$SNAP" 'PRAGMA integrity_check')" = ok ] || tt_die "integrity_check of the snapshot failed"
  tt_row_counts sqlite "$SNAP" >"$DEST/row_counts.tsv"
  tt_migrations sqlite "$SNAP" >"$DEST/migrations.txt"
  LOCAL_ROWS="$(tt_sqlite_q "$SNAP" "SELECT storage_key FROM stored_files WHERE backend='local' AND state='stored' ORDER BY storage_key" 2>/dev/null || true)"
  FILES_DB="$(tt_sqlite_q "$SNAP" "SELECT COUNT(*) FROM stored_files WHERE backend='db' AND state='stored'" 2>/dev/null || echo 0)"
  FILES_S3="$(tt_sqlite_q "$SNAP" "SELECT COUNT(*) FROM stored_files WHERE backend='s3' AND state='stored'" 2>/dev/null || echo 0)"
  S3_INFO="$(tt_sqlite_q "$SNAP" "SELECT IFNULL(s3_endpoint,'')||' '||IFNULL(s3_bucket,'') FROM storage_settings LIMIT 1" 2>/dev/null || true)"
  SERVER_VERSION="sqlite $(sqlite3 --version | cut -d' ' -f1)"
  gzip -n -9 "$SNAP"; ARTIFACT_DB="db.sqlite.gz"
else
  tt_log "mariadb-dump (single transaction) of database $DB_NAME_ARG"
  tt_db_client mariadb-dump --single-transaction --quick --skip-lock-tables --skip-add-locks --hex-blob "$DB_NAME_ARG" </dev/null | gzip -n -9 >"$DEST/db.sql.gz"
  [ "$(gzip -dc "$DEST/db.sql.gz" | grep -c '^-- Dump completed')" -eq 1 ] || tt_die "dump is incomplete (no completion marker)"
  tt_row_counts mariadb "$DB_NAME_ARG" >"$DEST/row_counts.tsv"
  tt_migrations mariadb "$DB_NAME_ARG" >"$DEST/migrations.txt"
  LOCAL_ROWS="$(tt_mysql_q "SELECT storage_key FROM stored_files WHERE backend='local' AND state='stored' ORDER BY storage_key" "$DB_NAME_ARG" 2>/dev/null || true)"
  FILES_DB="$(tt_mysql_q "SELECT COUNT(*) FROM stored_files WHERE backend='db' AND state='stored'" "$DB_NAME_ARG" 2>/dev/null || echo 0)"
  FILES_S3="$(tt_mysql_q "SELECT COUNT(*) FROM stored_files WHERE backend='s3' AND state='stored'" "$DB_NAME_ARG" 2>/dev/null || echo 0)"
  S3_INFO="$(tt_mysql_q "SELECT CONCAT(IFNULL(s3_endpoint,''),' ',IFNULL(s3_bucket,'')) FROM storage_settings LIMIT 1" "$DB_NAME_ARG" 2>/dev/null || true)"
  SERVER_VERSION="mariadb $(tt_mysql_q 'SELECT VERSION()')"
  ARTIFACT_DB="db.sql.gz"
fi
[ -s "$DEST/migrations.txt" ] || tt_die "no applied migrations found: is this a Timetrack database?"

# 2. Local files: hash list and tar share one file list, so archive and checksums describe the same set
ARTIFACT_FILES=""
FILE_COUNT=0
if [ -n "$LOCAL_FILES" ]; then
  tt_log "archiving local files from $LOCAL_FILES"
  (cd "$LOCAL_FILES" && find . -type f ! -name '.tmp-*' | sed 's|^\./||' | LC_ALL=C sort) >"$DEST/files.list"
  FILE_COUNT="$(wc -l <"$DEST/files.list" | tr -d ' ')"
  : >"$DEST/files.sha256"
  while IFS= read -r f; do
    printf '%s  %s\n' "$(tt_sha256 "$LOCAL_FILES/$f")" "$f" >>"$DEST/files.sha256"
  done <"$DEST/files.list"
  if [ "$FILE_COUNT" -gt 0 ]; then
    tar -czf "$DEST/files.tar.gz" -C "$LOCAL_FILES" -T "$DEST/files.list"
    ARTIFACT_FILES="files.tar.gz"
  fi
  # every stored local row must have its object in the archive (otherwise: upload/delete raced the backup)
  MISSING=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$DEST/files.list" || { MISSING=$((MISSING + 1)); tt_log "stored file row without archived object: $key"; }
  done <<<"$LOCAL_ROWS"
  if [ "$MISSING" -gt 0 ] && [ "$ALLOW_INCONSISTENT" -ne 1 ]; then
    tt_die "$MISSING stored local file row(s) have no object in the archive; stop writers or retry (or --allow-inconsistent)"
  fi
elif [ -n "$LOCAL_ROWS" ]; then
  tt_log "WARNING: database references local files but --local-files was not given; the archive will not contain them"
fi

# 3. Manifest (flat key=value, no secrets) and checksums
MIG_COUNT="$(wc -l <"$DEST/migrations.txt" | tr -d ' ')"
MIG_SHA="$(tt_sha256 "$DEST/migrations.txt")"
{
  echo "format=1"
  echo "created_utc=$STAMP"
  echo "driver=$DRIVER"
  echo "db_name=$([ "$DRIVER" = mariadb ] && echo "$DB_NAME_ARG" || echo "")"
  echo "server_version=$SERVER_VERSION"
  echo "artifact_db=$ARTIFACT_DB"
  echo "artifact_files=$ARTIFACT_FILES"
  echo "migrations_count=$MIG_COUNT"
  echo "migrations_sha256=$MIG_SHA"
  echo "local_root=$LOCAL_FILES"
  echo "files_local_archived=$FILE_COUNT"
  echo "files_local_rows=$(printf '%s' "$LOCAL_ROWS" | grep -c . || true)"
  echo "files_db_rows=$FILES_DB"
  echo "files_s3_rows=$FILES_S3"
  echo "s3_endpoint_bucket=${S3_INFO:-}"
  echo "note=S3 objects, STORAGE_SECRET_KEY, VAPID keys and DB passwords are NOT part of this backup (docs/BETRIEB.md)"
} >"$DEST/MANIFEST"

(
  cd "$DEST"
  for f in MANIFEST migrations.txt row_counts.tsv files.list files.sha256 "$ARTIFACT_DB" ${ARTIFACT_FILES:+"$ARTIFACT_FILES"}; do
    if [ -f "$f" ]; then printf '%s  %s\n' "$(tt_sha256 "$f")" "$f"; fi
  done >SHA256SUMS
)
chmod -R go-rwx "$DEST"
trap - EXIT
tt_log "backup complete: $DEST"
tt_log "  driver=$DRIVER migrations=$MIG_COUNT local_files=$FILE_COUNT db_files=$FILES_DB s3_files=$FILES_S3 tables=$(wc -l <"$DEST/row_counts.tsv" | tr -d ' ')"
echo "$DEST"
