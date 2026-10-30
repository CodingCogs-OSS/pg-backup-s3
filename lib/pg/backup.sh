#!/bin/sh
# /backup.sh for pg-backup-s3: one scheduled backup run.
#
#   1. run-parts /hooks with "pre-backup"
#   2. pg_dump (or pg_dumpall) each database to last/<db>-<stamp><suffix>.partial,
#      then rename it
#   3. hardlink into daily/ weekly/ monthly/, update -latest links (optional)
#   4. prune old files per BACKUP_KEEP_*
#   5. run-parts /hooks with "post-backup"
# Any failure runs the "error" hooks and exits non-zero, so go-cron and the
# healthcheck report the run as failed. The shared S3 layer (hooks/post-backup,
# s3-sync) never ships a *.partial file.
#
# Configuration: see /env.sh.
#
# Ported from prodrigestivill/docker-postgres-backup-local (MIT License,
# Copyright (c) 2023 Pau Rodriguez-Estivill and Johannes Schickling); see
# lib/pg/NOTICE (/usr/share/doc/pg-backup-s3/NOTICE.postgres-backup-local).
set -eu
HOOKS_DIR="${HOOKS_DIR:-/hooks}"
ENV_SH="${ENV_SH:-$(dirname "$0")/env.sh}"
log() { printf '[pg-backup] %s\n' "$*" >&2; }
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}
run_hooks() {
  [ -d "$HOOKS_DIR" ] || return 0
  _action="$1"; shift
  run-parts -a "$_action" "$@" "$HOOKS_DIR"
}
WORK_DIR=""
PARTIAL=""
on_exit() {
  rc=$?
  trap - EXIT
  [ -n "$PARTIAL" ] && rm -rf "$PARTIAL"
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  if [ "$rc" -ne 0 ]; then
    log "backup FAILED (exit $rc)"
    run_hooks error || true
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck source=/dev/null
. "$ENV_SH"
WORK_DIR=$(mktemp -d)
chmod 700 "$WORK_DIR"
run_hooks pre-backup --exit-on-error
mkdir -p "$BACKUP_DIR/last" "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly"
set -f
# shellcheck disable=SC2086
for DB in $POSTGRES_DBS; do
  set +f
  LAST_FILENAME="${DB}-$(date +%Y%m%d-%H%M%S)${BACKUP_SUFFIX}"
  DAILY_FILENAME="${DB}-$(date +%Y%m%d)${BACKUP_SUFFIX}"
  WEEKLY_FILENAME="${DB}-$(date +%G%V)${BACKUP_SUFFIX}"
  MONTHLY_FILENAME="${DB}-$(date +%Y%m)${BACKUP_SUFFIX}"
  FILE="$BACKUP_DIR/last/$LAST_FILENAME"
  DFILE="$BACKUP_DIR/daily/$DAILY_FILENAME"
  WFILE="$BACKUP_DIR/weekly/$WEEKLY_FILENAME"
  MFILE="$BACKUP_DIR/monthly/$MONTHLY_FILENAME"
  # dump options; -f so globs in POSTGRES_EXTRA_OPTS stay literal
  set -f
  # shellcheck disable=SC2086
  set -- $POSTGRES_EXTRA_OPTS
  set +f
  # write under a .partial name (s3-sync never ships those), rename when done
  PARTIAL="$FILE.partial"
  if is_true "$POSTGRES_CLUSTER"; then
    log "creating cluster dump of $DB from $POSTGRES_HOST"
    # dash has no pipefail: keep pg_dumpall's status in a file
    _rcf="$WORK_DIR/pg_dumpall.rc"
    rm -f "$_rcf"
    { pg_dumpall -l "$DB" "$@" || echo "$?" > "$_rcf"; } | gzip > "$PARTIAL"
    if [ -s "$_rcf" ]; then
      log "pg_dumpall failed (exit $(cat "$_rcf"))"
      exit 1
    fi
  else
    log "creating dump of $DB from $POSTGRES_HOST"
    pg_dump -d "$DB" -f "$PARTIAL" "$@"
  fi
  mv -f "$PARTIAL" "$FILE"
  PARTIAL=""
  # hard links into daily/ weekly/ monthly/
  if [ -d "$FILE" ]; then
    # directory-format dump: link every file of it
    rm -rf "$DFILE-new" "$WFILE-new" "$MFILE-new"
    mkdir "$DFILE-new" "$WFILE-new" "$MFILE-new"
    (
      cd "$FILE"
      for F in *; do
        ln -f "$F" "$DFILE-new/"
        ln -f "$F" "$WFILE-new/"
        ln -f "$F" "$MFILE-new/"
      done
    )
    rm -rf "$DFILE" "$WFILE" "$MFILE"
    mv "$DFILE-new" "$DFILE"
    mv "$WFILE-new" "$WFILE"
    mv "$MFILE-new" "$MFILE"
  else
    ln -f "$FILE" "$DFILE"
    ln -f "$FILE" "$WFILE"
    ln -f "$FILE" "$MFILE"
  fi
  case "$BACKUP_LATEST_TYPE" in
    symlink|hardlink)
      if [ "$BACKUP_LATEST_TYPE" = symlink ]; then ln_arg="-sf"; else ln_arg="-f"; fi
      # symlinks are relative to the directory they live in
      (
        cd "$BACKUP_DIR/last" && ln "$ln_arg" "$LAST_FILENAME" "${DB}-latest${BACKUP_SUFFIX}"
        cd "$BACKUP_DIR/daily" && ln "$ln_arg" "$DAILY_FILENAME" "${DB}-latest${BACKUP_SUFFIX}"
        cd "$BACKUP_DIR/weekly" && ln "$ln_arg" "$WEEKLY_FILENAME" "${DB}-latest${BACKUP_SUFFIX}"
        cd "$BACKUP_DIR/monthly" && ln "$ln_arg" "$MONTHLY_FILENAME" "${DB}-latest${BACKUP_SUFFIX}"
      )
      ;;
    *)
      log "not updating latest backup links"
      ;;
  esac
  log "pruning old backups of $DB"
  find "$BACKUP_DIR/last" -maxdepth 1 -mmin "+$KEEP_MINS" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  find "$BACKUP_DIR/daily" -maxdepth 1 -mtime "+$KEEP_DAYS" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  find "$BACKUP_DIR/weekly" -maxdepth 1 -mtime "+$KEEP_WEEKS" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  find "$BACKUP_DIR/monthly" -maxdepth 1 -mtime "+$KEEP_MONTHS" -name "${DB}-*${BACKUP_SUFFIX}" -exec rm -rf '{}' ';'
  # leftovers of a run that was killed mid-dump
  find "$BACKUP_DIR/last" -maxdepth 1 -mmin "+$KEEP_MINS" -name "${DB}-*${BACKUP_SUFFIX}.partial" -exec rm -rf '{}' ';'
  set -f
done
set +f
log "SQL backup created successfully"
run_hooks post-backup --reverse --exit-on-error
