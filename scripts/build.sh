#!/bin/sh
# Local image builds for the host architecture (docker build from the repo root).
#
#   sh scripts/build.sh [all]            every pg major and the mongo image
#   sh scripts/build.sh pg [<major>...]  pg images (default: every major in docker/versions.env)
#   sh scripts/build.sh mongo            the mongo image (all version tags)
#
# DOCKER_BUILD_FLAGS adds flags to docker build, e.g. "--pull --no-cache".
# Versions and image names come from docker/versions.env. The official images
# are published by CI only (.github/workflows/images.yml).
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./docker/versions.env

log() { printf '[build] %s\n' "$*" >&2; }
usage() {
  printf 'usage: sh scripts/build.sh [all | pg [<major>...] | mongo]\n' >&2
  exit 2
}
last() { for _x in $1; do :; done; printf '%s' "$_x"; }
check_list() {
  for _v in $2; do
    case "$_v" in
      ''|*[!0-9.]*) log "$1 in docker/versions.env may only contain digits and dots (got '$_v')"; exit 2 ;;
    esac
  done
}
check_list PG_MAJORS "$PG_MAJORS"
check_list MONGO_VERSIONS "$MONGO_VERSIONS"

# run docker build with the given arguments after the user's flags
run_build() {
  set -f
  # shellcheck disable=SC2086
  set -- ${DOCKER_BUILD_FLAGS:-} "$@"
  set +f
  log "docker build $*"
  docker build "$@"
}

build_pg() {
  _m="$1"
  _found=0
  for _v in $PG_MAJORS; do [ "$_v" = "$_m" ] && _found=1; done
  if [ "$_found" -ne 1 ]; then
    log "unknown PostgreSQL major '$_m' (see docker/versions.env)"
    exit 2
  fi
  set -- -f docker/Dockerfile.pg-backup --build-arg "PG_MAJOR=$_m" -t "$PG_IMAGE:$_m"
  _tags="$PG_IMAGE:$_m"
  if [ "$_m" = "$(last "$PG_MAJORS")" ]; then
    set -- "$@" -t "$PG_IMAGE:latest"
    _tags="$_tags $PG_IMAGE:latest"
  fi
  run_build "$@" .
  log "built $_tags"
}

build_mongo() {
  set -- -f docker/Dockerfile.mongo-backup
  _tags=""
  for _v in $MONGO_VERSIONS latest; do
    set -- "$@" -t "$MONGO_IMAGE:$_v"
    _tags="$_tags $MONGO_IMAGE:$_v"
  done
  run_build "$@" .
  log "built$_tags"
}

target="${1:-all}"
[ "$#" -eq 0 ] || shift
case "$target" in
  all)
    [ "$#" -eq 0 ] || usage
    for _m in $PG_MAJORS; do build_pg "$_m"; done
    build_mongo ;;
  pg)
    # shellcheck disable=SC2086
    if [ "$#" -eq 0 ]; then set -- $PG_MAJORS; fi
    for _m in "$@"; do build_pg "$_m"; done ;;
  mongo)
    [ "$#" -eq 0 ] || usage
    build_mongo ;;
  *) usage ;;
esac
