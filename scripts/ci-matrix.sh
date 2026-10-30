#!/bin/sh
# Build and publish matrices for .github/workflows/images.yml.
#
#   sh scripts/ci-matrix.sh >> "$GITHUB_OUTPUT"
#
# Inputs (environment):
#   STAMP               UTC build time as YYYYMMDDTHHMMSSZ (default: now)
#   GITHUB_EVENT_NAME   publish only when this is not "pull_request"
#   GITHUB_REF          ... and this is refs/heads/main
#
# Output, exactly four lines: stamp=, publish=, build_matrix=, publish_matrix=.
# Versions and image names come from docker/versions.env.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./docker/versions.env

die() { printf '[ci-matrix] %s\n' "$*" >&2; exit 1; }
last() { for _x in $1; do :; done; printf '%s' "$_x"; }
for _v in $PG_MAJORS $MONGO_VERSIONS; do
  case "$_v" in
    ''|*[!0-9.]*) die "versions in docker/versions.env may only contain digits and dots (got '$_v')" ;;
  esac
done

STAMP="${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
case "$STAMP" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) die "STAMP must look like 20261030T031700Z (got '$STAMP')" ;;
esac

publish=false
if [ "${GITHUB_EVENT_NAME:-}" != pull_request ] && [ "${GITHUB_REF:-}" = refs/heads/main ]; then
  publish=true
fi

PG_REPO="docker.io/$PG_IMAGE"
MONGO_REPO="docker.io/$MONGO_IMAGE"
last_pg=$(last "$PG_MAJORS")

build=""
add_build() {
  # kind variant build_args repo dockerfile tests
  for _a in amd64:ubuntu-24.04 arm64:ubuntu-24.04-arm; do
    _arch="${_a%%:*}"
    _runner="${_a#*:}"
    _e="{\"kind\":\"$1\",\"variant\":\"$2\",\"arch\":\"$_arch\",\"runner\":\"$_runner\",\"dockerfile\":\"$5\",\"build_args\":\"$3\",\"repo\":\"$4\",\"tests\":\"$6\"}"
    if [ -z "$build" ]; then build="$_e"; else build="$build,$_e"; fi
  done
}
for m in $PG_MAJORS; do
  add_build pg "$m" "PG_MAJOR=$m" "$PG_REPO" docker/Dockerfile.pg-backup "$m"
done
add_build mongo mongo "" "$MONGO_REPO" docker/Dockerfile.mongo-backup "$MONGO_VERSIONS"

publish_list=""
add_publish() {
  _e="{\"variant\":\"$1\",\"repo\":\"$2\",\"tags\":\"$3\"}"
  if [ -z "$publish_list" ]; then publish_list="$_e"; else publish_list="$publish_list,$_e"; fi
}
for m in $PG_MAJORS; do
  tags="$m $m-$STAMP"
  [ "$m" = "$last_pg" ] && tags="$tags latest"
  add_publish "$m" "$PG_REPO" "$tags"
done
tags=""
for v in $MONGO_VERSIONS; do
  tags="${tags:+$tags }$v $v-$STAMP"
done
add_publish mongo "$MONGO_REPO" "$tags latest"

printf 'stamp=%s\n' "$STAMP"
printf 'publish=%s\n' "$publish"
printf 'build_matrix={"include":[%s]}\n' "$build"
printf 'publish_matrix={"include":[%s]}\n' "$publish_list"
