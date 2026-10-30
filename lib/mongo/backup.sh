#!/bin/sh
# /backup.sh for mongo-backup-s3: one scheduled backup run.
#
# Mirrors prodrigestivill/postgres-backup-local's backup.sh so the shared S3
# layer (hooks/post-backup, s3-sync) works unchanged:
#   1. run-parts /hooks with "pre-backup"
#   2. mongodump each target to last/<name>-<stamp><suffix>.partial, then rename
#   3. hardlink into daily/ weekly/ monthly/, update -latest links (optional)
#   4. prune old files per BACKUP_KEEP_*
#   5. run-parts /hooks with "post-backup"
# Any failure runs the "error" hooks and exits non-zero, so go-cron and the
# healthcheck report the run as failed.
#
# Configuration: see /env.sh.

set -eu

HOOKS_DIR="${HOOKS_DIR:-/hooks}"
ENV_SH="${ENV_SH:-/env.sh}"

log() { printf '[mongo-backup] %s\n' "$*" >&2; }

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
  [ -n "$PARTIAL" ] && rm -f "$PARTIAL"
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

# YAML single-quoted scalar: wrap in '...' and double any embedded quote
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# secrets go into a private --config file instead of argv (visible in ps)
WORK_DIR=$(mktemp -d)
chmod 700 "$WORK_DIR"
CONFIG=""
if [ -n "$MONGO_URI_VALUE" ] || [ -n "$MONGO_PASSWORD_VALUE" ]; then
  CONFIG="$WORK_DIR/mongodump.yaml"
  (
    umask 077
    : >"$CONFIG"
    [ -n "$MONGO_URI_VALUE" ] && printf 'uri: %s\n' "$(yaml_quote "$MONGO_URI_VALUE")" >>"$CONFIG"
    [ -n "$MONGO_PASSWORD_VALUE" ] && printf 'password: %s\n' "$(yaml_quote "$MONGO_PASSWORD_VALUE")" >>"$CONFIG"
    :
  )
fi

run_hooks pre-backup --exit-on-error

mkdir -p "$BACKUP_DIR/last" "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly"

if [ -n "$MONGO_URI_VALUE" ]; then
  source_desc="MONGO_URI"
else
  source_desc="$MONGO_HOST:$MONGO_PORT"
fi

for NAME in $MONGO_TARGETS; do
  LAST_FILENAME="${NAME}-$(date +%Y%m%d-%H%M%S)${BACKUP_SUFFIX}"
  DAILY_FILENAME="${NAME}-$(date +%Y%m%d)${BACKUP_SUFFIX}"
  WEEKLY_FILENAME="${NAME}-$(date +%G%V)${BACKUP_SUFFIX}"
  MONTHLY_FILENAME="${NAME}-$(date +%Y%m)${BACKUP_SUFFIX}"
  FILE="$BACKUP_DIR/last/$LAST_FILENAME"
  DFILE="$BACKUP_DIR/daily/$DAILY_FILENAME"
  WFILE="$BACKUP_DIR/weekly/$WEEKLY_FILENAME"
  MFILE="$BACKUP_DIR/monthly/$MONTHLY_FILENAME"

  # build mongodump arguments; -f so globs in MONGO_EXTRA_OPTS stay literal
  set -f
  # shellcheck disable=SC2086
  set -- $MONGO_EXTRA_OPTS
  set +f
  [ -n "$CONFIG" ] && set -- "$@" --config="$CONFIG"
  if [ -z "$MONGO_URI_VALUE" ]; then
    set -- "$@" --host="$MONGO_HOST" --port="$MONGO_PORT"
  fi
  if [ -n "$MONGO_USER_VALUE" ]; then
    set -- "$@" --username="$MONGO_USER_VALUE" --authenticationDatabase="$MONGO_AUTH_DB"
  fi
  if [ "$MONGO_WHOLE_INSTANCE" = true ]; then
    log "dumping the whole instance ($source_desc) to $FILE"
  else
    set -- "$@" --db="$NAME"
    log "dumping database $NAME ($source_desc) to $FILE"
  fi

  # write under a .partial name (s3-sync never ships those), rename when done
  PARTIAL="$FILE.partial"
  mongodump "$@" --archive="$PARTIAL" --gzip
  mv -f "$PARTIAL" "$FILE"
  PARTIAL=""

  ln -f "$FILE" "$DFILE"
  ln -f "$FILE" "$WFILE"
  ln -f "$FILE" "$MFILE"

  case "$BACKUP_LATEST_TYPE" in
    symlink|hardlink)
      if [ "$BACKUP_LATEST_TYPE" = symlink ]; then ln_arg="-sf"; else ln_arg="-f"; fi
      # symlinks are relative to the directory they live in
      (
        cd "$BACKUP_DIR/last" && ln "$ln_arg" "$LAST_FILENAME" "${NAME}-latest${BACKUP_SUFFIX}"
        cd "$BACKUP_DIR/daily" && ln "$ln_arg" "$DAILY_FILENAME" "${NAME}-latest${BACKUP_SUFFIX}"
        cd "$BACKUP_DIR/weekly" && ln "$ln_arg" "$WEEKLY_FILENAME" "${NAME}-latest${BACKUP_SUFFIX}"
        cd "$BACKUP_DIR/monthly" && ln "$ln_arg" "$MONTHLY_FILENAME" "${NAME}-latest${BACKUP_SUFFIX}"
      )
      ;;
  esac

  log "pruning old backups of $NAME"
  find "$BACKUP_DIR/last" -maxdepth 1 -mmin "+$KEEP_MINS" -name "${NAME}-*${BACKUP_SUFFIX}" -exec rm -f '{}' ';'
  find "$BACKUP_DIR/daily" -maxdepth 1 -mtime "+$KEEP_DAYS" -name "${NAME}-*${BACKUP_SUFFIX}" -exec rm -f '{}' ';'
  find "$BACKUP_DIR/weekly" -maxdepth 1 -mtime "+$KEEP_WEEKS" -name "${NAME}-*${BACKUP_SUFFIX}" -exec rm -f '{}' ';'
  find "$BACKUP_DIR/monthly" -maxdepth 1 -mtime "+$KEEP_MONTHS" -name "${NAME}-*${BACKUP_SUFFIX}" -exec rm -f '{}' ';'
  # leftovers of a run that was killed mid-dump
  find "$BACKUP_DIR/last" -maxdepth 1 -mmin "+$KEEP_MINS" -name "${NAME}-*${BACKUP_SUFFIX}.partial" -exec rm -f '{}' ';'
done

log "backup completed"

run_hooks post-backup --reverse --exit-on-error
