#!/bin/sh
# shellcheck disable=SC2034  # variables are consumed by /backup.sh, which sources this
# /env.sh for mongo-backup-s3: validate the configuration and derive the values
# /backup.sh needs. Sourced by /backup.sh; run standalone by /init.sh to fail
# fast at container start (VALIDATE_ON_START). Never prints secret values.
#
# Connection
#   MONGO_URI[_FILE]        full connection string (replica sets, mongodb+srv://,
#                           TLS options). When set, MONGO_HOST/MONGO_PORT are
#                           ignored. Don't combine credentials in the URI with
#                           MONGO_USER/MONGO_PASSWORD.
#   MONGO_HOST, MONGO_PORT  used when no URI is set (port default 27017)
#   MONGO_USER[_FILE]       optional; enables --username/--authenticationDatabase
#   MONGO_PASSWORD[_FILE]   optional
#   MONGO_AUTH_DB           authentication database (default admin)
#
# What to dump
#   MONGO_DB[_FILE]         comma/space separated databases, one archive each.
#                           Empty (default) dumps the whole instance into one
#                           archive named after MONGO_DUMP_NAME (default "all").
#   MONGO_EXTRA_OPTS        extra mongodump flags, e.g. "--oplog"
#
# Secrets (URI, password) are handed to mongodump through a 0600 --config file,
# never on the command line.

set -eu

_env_err() { printf '[mongo-backup] %s\n' "$*" >&2; }

# value of $1, or the contents of the file named by ${1}_FILE
_env_read() {
  eval "_ev=\${$1:-}"
  eval "_ef=\${$1_FILE:-}"
  if [ -z "$_ev" ] && [ -n "$_ef" ]; then
    if [ ! -r "$_ef" ]; then
      _env_err "$1_FILE points to '$_ef', which is not readable"
      return 1
    fi
    _ev=$(cat "$_ef")
  fi
  printf '%s' "$_ev"
}

_env_uint() {
  case "${2:-}" in
    ''|*[!0-9]*) _env_err "$1 must be a non-negative integer (got '${2:-}')"; return 1 ;;
  esac
}

MONGO_URI_VALUE=$(_env_read MONGO_URI) || exit 1
MONGO_USER_VALUE=$(_env_read MONGO_USER) || exit 1
MONGO_PASSWORD_VALUE=$(_env_read MONGO_PASSWORD) || exit 1
MONGO_DB_VALUE=$(_env_read MONGO_DB) || exit 1
MONGO_HOST="${MONGO_HOST:-}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"
MONGO_EXTRA_OPTS="${MONGO_EXTRA_OPTS:-}"
MONGO_DUMP_NAME="${MONGO_DUMP_NAME:-all}"

if [ -z "$MONGO_URI_VALUE" ] && [ -z "$MONGO_HOST" ]; then
  _env_err "set MONGO_URI (or MONGO_URI_FILE) or MONGO_HOST"
  exit 1
fi
if [ -n "$MONGO_PASSWORD_VALUE" ] && [ -z "$MONGO_USER_VALUE" ] && [ -z "$MONGO_URI_VALUE" ]; then
  _env_err "MONGO_PASSWORD is set but MONGO_USER is not"
  exit 1
fi
_env_uint MONGO_PORT "$MONGO_PORT" || exit 1

# dump targets: database names, or the whole-instance name
if [ -n "$MONGO_DB_VALUE" ]; then
  MONGO_WHOLE_INSTANCE=false
  MONGO_TARGETS=$(printf '%s' "$MONGO_DB_VALUE" | tr ',\n\t' '   ')
else
  MONGO_WHOLE_INSTANCE=true
  MONGO_TARGETS="$MONGO_DUMP_NAME"
fi
for _t in $MONGO_TARGETS; do
  case "$_t" in
    *[!A-Za-z0-9._-]*)
      _env_err "'$_t' can't be used in a backup file name (allowed: A-Z a-z 0-9 . _ -)"
      exit 1 ;;
  esac
done
if [ -z "$(printf '%s' "$MONGO_TARGETS" | tr -d ' ')" ]; then
  _env_err "MONGO_DB is set but lists no database"
  exit 1
fi

# rotation, same semantics as prodrigestivill/postgres-backup-local
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_SUFFIX="${BACKUP_SUFFIX:-.archive.gz}"
BACKUP_LATEST_TYPE="${BACKUP_LATEST_TYPE:-none}"
_env_uint BACKUP_KEEP_MINS "${BACKUP_KEEP_MINS:=1440}" || exit 1
_env_uint BACKUP_KEEP_DAYS "${BACKUP_KEEP_DAYS:=7}" || exit 1
_env_uint BACKUP_KEEP_WEEKS "${BACKUP_KEEP_WEEKS:=4}" || exit 1
_env_uint BACKUP_KEEP_MONTHS "${BACKUP_KEEP_MONTHS:=6}" || exit 1
KEEP_MINS=$BACKUP_KEEP_MINS
KEEP_DAYS=$BACKUP_KEEP_DAYS
KEEP_WEEKS=$((BACKUP_KEEP_WEEKS * 7 + 1))
KEEP_MONTHS=$((BACKUP_KEEP_MONTHS * 31 + 1))

case "$BACKUP_LATEST_TYPE" in
  symlink|hardlink|none) ;;
  *) _env_err "BACKUP_LATEST_TYPE must be symlink, hardlink or none"; exit 1 ;;
esac

if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ] || [ ! -x "$BACKUP_DIR" ]; then
  _env_err "BACKUP_DIR ($BACKUP_DIR) is not a writable directory"
  exit 1
fi

if ! command -v mongodump >/dev/null 2>&1; then
  _env_err "mongodump not found in PATH"
  exit 1
fi
