#!/bin/sh
# /init.sh for pg-backup-s3: validate the configuration, then run /backup.sh
# on SCHEDULE via go-cron (which also serves the healthcheck on
# HEALTHCHECK_PORT). Started by pg-backup-s3-entrypoint.
#
# Ported from prodrigestivill/docker-postgres-backup-local (MIT License,
# Copyright (c) 2023 Pau Rodriguez-Estivill and Johannes Schickling); see
# lib/pg/NOTICE (/usr/share/doc/pg-backup-s3/NOTICE.postgres-backup-local).
set -eu
log() { printf '[pg-backup] %s\n' "$*" >&2; }
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}
# go-cron accepts robfig/cron specs: 5 fields, 6 with optional leading seconds,
# or a descriptor (@daily, @every 6h, ...). It silently ignores a spec it cannot
# parse, which would mean "never backs up", so reject bad specs loudly up front.
valid_schedule() {
  _spec="$1"
  # robfig/cron accepts an optional leading CRON_TZ=<zone> or TZ=<zone> token
  case "$_spec" in
    CRON_TZ=*|TZ=*)
      case "$_spec" in *" "*) _spec="${_spec#* }" ;; *) return 1 ;; esac ;;
  esac
  case "$_spec" in
    "@every "*)
      [ -n "$(printf '%s' "${_spec#@every }" | tr -d '[:space:]')" ] ;;
    @annually|@yearly|@monthly|@weekly|@daily|@midnight|@hourly)
      : ;;
    @*)
      return 1 ;;
    *)
      # -f so that the "*" fields of a cron spec are not glob-expanded
      set -f
      # shellcheck disable=SC2086
      set -- $_spec
      _n="$#"
      set +f
      [ "$_n" -ge 5 ] && [ "$_n" -le 6 ] ;;
  esac
}
SCHEDULE="${SCHEDULE:-@daily}"
if ! valid_schedule "$SCHEDULE"; then
  log "invalid SCHEDULE '$SCHEDULE' (expected a 5/6 field cron spec or a descriptor like @daily / @every 6h)"
  exit 1
fi
if is_true "${VALIDATE_ON_START:-TRUE}"; then
  /env.sh
fi
extra=""
if is_true "${BACKUP_ON_START:-FALSE}"; then
  extra="-i"
fi
# shellcheck disable=SC2086
exec /usr/local/bin/go-cron -s "$SCHEDULE" -p "${HEALTHCHECK_PORT:-8080}" $extra -- /backup.sh
