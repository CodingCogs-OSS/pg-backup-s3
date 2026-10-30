#!/bin/sh
# shellcheck disable=SC2034  # variables are consumed by /backup.sh, which sources this
# /env.sh for pg-backup-s3: validate the configuration and derive the values
# /backup.sh needs. Sourced by /backup.sh; run standalone by /init.sh to fail
# fast at container start (VALIDATE_ON_START). Never prints secret values.
#
# Connection (empty or "**None**" means unset)
#   POSTGRES_HOST                 server host; falls back to
#                                 POSTGRES_PORT_5432_TCP_ADDR (+ _PORT) from
#                                 legacy Docker links
#   POSTGRES_PORT                 default 5432
#   POSTGRES_USER[_FILE]          the _FILE variant wins when both are set
#   POSTGRES_PASSWORD[_FILE]      the _FILE variant wins when both are set
#   POSTGRES_PASSFILE_STORE       path of a libpq passfile (used when neither
#                                 password variable is set)
# What to dump
#   POSTGRES_DB[_FILE]            comma/space separated databases (the file may
#                                 list one per line); one dump each
#   POSTGRES_CLUSTER              true: pg_dumpall instead of pg_dump
#   POSTGRES_EXTRA_OPTS           extra pg_dump/pg_dumpall flags (default -Z1)
# Rotation
#   BACKUP_DIR, BACKUP_SUFFIX, BACKUP_LATEST_TYPE (symlink|hardlink, anything
#   else = no links), BACKUP_KEEP_MINS/DAYS/WEEKS/MONTHS
#
# Ported from prodrigestivill/docker-postgres-backup-local (MIT License,
# Copyright (c) 2023 Pau Rodriguez-Estivill and Johannes Schickling); see
# lib/pg/NOTICE (/usr/share/doc/pg-backup-s3/NOTICE.postgres-backup-local).
set -eu
_env_err() { printf '[pg-backup] %s\n' "$*" >&2; }
# true when $1 is empty or the "**None**" sentinel
_env_none() { [ -z "${1:-}" ] || [ "$1" = '**None**' ]; }
_env_uint() {
  case "${2:-}" in
    ''|*[!0-9]*) _env_err "$1 must be a non-negative integer (got '${2:-}')"; return 1 ;;
  esac
}
# 1. databases
_dbf="${POSTGRES_DB_FILE:-}"
if _env_none "$_dbf"; then
  if _env_none "${POSTGRES_DB:-}"; then
    _env_err "You need to set the POSTGRES_DB or POSTGRES_DB_FILE environment variable."
    exit 1
  fi
  POSTGRES_DBS=$(printf '%s' "$POSTGRES_DB" | tr ',' ' ')
elif [ -r "$_dbf" ]; then
  POSTGRES_DBS=$(tr ',\n\t' '   ' < "$_dbf")
else
  _env_err "Missing POSTGRES_DB_FILE file."
  exit 1
fi
if [ -z "$(printf '%s' "$POSTGRES_DBS" | tr -d ' ')" ]; then
  _env_err "POSTGRES_DB lists no database."
  exit 1
fi
# 2. host and port
if _env_none "${POSTGRES_HOST:-}"; then
  if [ -n "${POSTGRES_PORT_5432_TCP_ADDR:-}" ]; then
    POSTGRES_HOST="$POSTGRES_PORT_5432_TCP_ADDR"
    POSTGRES_PORT="${POSTGRES_PORT_5432_TCP_PORT:-5432}"
  else
    _env_err "You need to set the POSTGRES_HOST environment variable."
    exit 1
  fi
fi
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
_env_uint POSTGRES_PORT "$POSTGRES_PORT" || exit 1
# 3. user
if ! _env_none "${POSTGRES_USER_FILE:-}"; then
  if [ -r "$POSTGRES_USER_FILE" ]; then
    PGUSER=$(cat "$POSTGRES_USER_FILE")
  else
    _env_err "Missing POSTGRES_USER_FILE file."
    exit 1
  fi
elif ! _env_none "${POSTGRES_USER:-}"; then
  PGUSER="$POSTGRES_USER"
else
  _env_err "You need to set the POSTGRES_USER or POSTGRES_USER_FILE environment variable."
  exit 1
fi
export PGUSER
# 4. password (the libpq environment variables keep it off the command line)
if _env_none "${POSTGRES_PASSWORD_FILE:-}" && _env_none "${POSTGRES_PASSFILE_STORE:-}"; then
  if _env_none "${POSTGRES_PASSWORD:-}"; then
    _env_err "You need to set the POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE or POSTGRES_PASSFILE_STORE environment variable."
    exit 1
  fi
  PGPASSWORD="$POSTGRES_PASSWORD"
  export PGPASSWORD
elif ! _env_none "${POSTGRES_PASSWORD_FILE:-}" && [ -r "$POSTGRES_PASSWORD_FILE" ]; then
  PGPASSWORD=$(cat "$POSTGRES_PASSWORD_FILE")
  export PGPASSWORD
elif ! _env_none "${POSTGRES_PASSFILE_STORE:-}" && [ -r "$POSTGRES_PASSFILE_STORE" ]; then
  PGPASSFILE="$POSTGRES_PASSFILE_STORE"
  export PGPASSFILE
else
  _env_err "Missing POSTGRES_PASSWORD_FILE or POSTGRES_PASSFILE_STORE file."
  exit 1
fi
# 5. connection
PGHOST="$POSTGRES_HOST"
PGPORT="$POSTGRES_PORT"
export PGHOST PGPORT
# 6. options (unset = -Z1; set but empty stays empty)
POSTGRES_EXTRA_OPTS="${POSTGRES_EXTRA_OPTS--Z1}"
POSTGRES_CLUSTER="${POSTGRES_CLUSTER:-FALSE}"
# 7. rotation, same semantics as prodrigestivill/postgres-backup-local
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_SUFFIX="${BACKUP_SUFFIX:-.sql.gz}"
BACKUP_LATEST_TYPE="${BACKUP_LATEST_TYPE:-symlink}"
_env_uint BACKUP_KEEP_MINS "${BACKUP_KEEP_MINS:=1440}" || exit 1
_env_uint BACKUP_KEEP_DAYS "${BACKUP_KEEP_DAYS:=7}" || exit 1
_env_uint BACKUP_KEEP_WEEKS "${BACKUP_KEEP_WEEKS:=4}" || exit 1
_env_uint BACKUP_KEEP_MONTHS "${BACKUP_KEEP_MONTHS:=6}" || exit 1
KEEP_MINS=$BACKUP_KEEP_MINS
KEEP_DAYS=$BACKUP_KEEP_DAYS
KEEP_WEEKS=$((BACKUP_KEEP_WEEKS * 7 + 1))
KEEP_MONTHS=$((BACKUP_KEEP_MONTHS * 31 + 1))
# 8. the backup directory
if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ] || [ ! -x "$BACKUP_DIR" ]; then
  _env_err "BACKUP_DIR ($BACKUP_DIR) is not a writable directory for uid $(id -u); with --user, the mounted volume must be owned by that user (see README)."
  exit 1
fi
# 9. the client
if ! command -v pg_dump >/dev/null 2>&1; then
  _env_err "pg_dump not found in PATH"
  exit 1
fi
