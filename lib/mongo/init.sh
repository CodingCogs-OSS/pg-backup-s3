#!/bin/sh
# /init.sh for mongo-backup-s3: validate the configuration, then run /backup.sh
# on SCHEDULE via go-cron (which also serves the healthcheck on
# HEALTHCHECK_PORT). Started by mongo-backup-s3-entrypoint.

set -eu

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if is_true "${VALIDATE_ON_START:-true}"; then
  /env.sh
fi

extra=""
if is_true "${BACKUP_ON_START:-false}"; then
  extra="-i"
fi

# shellcheck disable=SC2086
exec /usr/local/bin/go-cron -s "${SCHEDULE:-@daily}" -p "${HEALTHCHECK_PORT:-8080}" $extra -- /backup.sh
