#!/bin/sh
# End-to-end test of one backup image against one database version.
#
#   sh tests/e2e.sh pg    <image> <pg-major>        e.g. cc0funobit/pg-backup-s3:18 18
#   sh tests/e2e.sh mongo <image> <mongo-version>   e.g. cc0funobit/mongo-backup-s3:latest 9.0
#
# Needs only Docker and a POSIX shell (Git Bash, Linux). It starts the database
# (postgres:<major> or mongo:<version>), an S3-compatible server and, for pg, a
# webhook receiver, then checks:
#   - image facts, `s3-sync --list`, startup rejection of bad cron specs
#   - a backup to three destinations (plain, gpg, openssl): local rotation
#     layout, bucket contents, download + decrypt + byte compare
#   - restore into a second database and a data hash compare
#   - the same backup under a non-root --user
#   - the default-command service path with its healthcheck and a scheduled
#     destination
#   - a failing backup (error hook, no leftover .partial file)
#
# Environment:
#   E2E_S3_IMAGE    S3-compatible server (default chrislusf/seaweedfs:4.51)
#   E2E_HOOK_IMAGE  webhook receiver image (default busybox:stable)
#   E2E_USER        uid:gid for the non-root run (default 10001:10001)
#   E2E_KEEP=1      keep the containers and volumes for debugging
#
# Prints "E2E PASS: <kind> <version> (<image>)" and exits 0, or "E2E FAIL: ..."
# on stderr with the tail of every container log and exits 1. Usage error: 2.
set -eu
# Git Bash must not rewrite container paths; harmless elsewhere
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

if [ "$#" -ne 3 ]; then
  printf 'usage: sh tests/e2e.sh pg|mongo <image> <db-version>\n' >&2
  exit 2
fi
KIND="$1"
IMAGE="$2"
VERSION="$3"
case "$KIND" in pg|mongo) ;; *) printf 'usage: sh tests/e2e.sh pg|mongo <image> <db-version>\n' >&2; exit 2 ;; esac
case "$VERSION" in ''|*[!0-9.]*) printf 'invalid database version: %s\n' "$VERSION" >&2; exit 2 ;; esac

E2E_S3_IMAGE="${E2E_S3_IMAGE:-chrislusf/seaweedfs:4.51}"
E2E_HOOK_IMAGE="${E2E_HOOK_IMAGE:-busybox:stable}"
E2E_USER="${E2E_USER:-10001:10001}"
P="e2e-$$-$(date +%s)"
DB_PASS=e2e-db-secret
ENC_PASS='correct horse battery staple'
S3_SECRET=e2e-s3-secret
S3_ENDPOINT="http://$P-s3:8333"

if [ "$KIND" = pg ]; then
  DBS="app app2"
  SUFFIX=".sql.gz"
  LATEST=symlink
else
  DBS="all"
  SUFFIX=".archive.gz"
  LATEST=none
fi

log() { printf '[e2e] %s\n' "$*" >&2; }
CONTAINERS="$P-db $P-db2 $P-s3 $P-hook $P-svc $P-bad1 $P-bad2"
VOLUMES="$P-secrets $P-work $P-bk-root $P-bk-user $P-bk-svc $P-bk-fail"
cleanup() {
  [ "${E2E_KEEP:-}" = 1 ] && return 0
  # shellcheck disable=SC2086
  docker rm -f $CONTAINERS >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker volume rm -f $VOLUMES >/dev/null 2>&1 || true
  docker network rm "$P-net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() {
  printf 'E2E FAIL: %s\n' "$*" >&2
  for _c in $CONTAINERS; do
    if docker inspect "$_c" >/dev/null 2>&1; then
      printf '== last 50 log lines of %s\n' "$_c" >&2
      docker logs --tail 50 "$_c" >&2 2>&1 || true
    fi
  done
  exit 1
}
# run a command every second until it succeeds or $1 seconds have passed
retry() {
  _t="$1"; shift
  _i=0
  while [ "$_i" -lt "$_t" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    _i=$((_i + 1))
    sleep 1
  done
  return 1
}
# command output without carriage returns; fails when the command fails
cap() {
  _o=$("$@") || return 1
  printf '%s' "$_o" | tr -d '\r'
}

# docker run flags
s3_env() {
  # $1 label (S3 prefix); $2 = 3 adds the openssl destination
  printf '%s ' \
    "-e S3_ENDPOINT=$S3_ENDPOINT" "-e AWS_ACCESS_KEY_ID=test" \
    "-e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/aws_secret" "-e AWS_DEFAULT_REGION=us-east-1" \
    "-e S3_PREFIX=$1" "-e S3_BUCKET=hot" \
    "-e S3_BUCKET_2=enc" "-e ENCRYPTION_ENABLED_2=true" "-e ENCRYPTION_PASSPHRASE_2_FILE=/run/secrets/enc_pass"
  if [ "${2:-}" = 3 ]; then
    printf '%s ' \
      "-e S3_BUCKET_3=encssl" "-e ENCRYPTION_ENABLED_3=true" "-e ENCRYPTION_METHOD_3=openssl" \
      "-e ENCRYPTION_PASSPHRASE_3_FILE=/run/secrets/enc_pass"
  fi
}
db_env() {
  # $1 label (webhook paths); $2 = wrong uses a bad password
  if [ "$KIND" = pg ]; then
    printf '%s ' "-e POSTGRES_HOST=$P-db" "-e POSTGRES_DB=app,app2" "-e POSTGRES_USER=postgres"
    if [ "${2:-}" = wrong ]; then
      printf '%s ' "-e POSTGRES_PASSWORD=wrong"
    else
      printf '%s ' "-e POSTGRES_PASSWORD_FILE=/run/secrets/db_password"
    fi
    printf '%s ' \
      "-e WEBHOOK_PRE_BACKUP_URL=http://$P-hook:8080/pre-$1" \
      "-e WEBHOOK_POST_BACKUP_URL=http://$P-hook:8080/post-$1" \
      "-e WEBHOOK_ERROR_URL=http://$P-hook:8080/error-$1"
  else
    printf '%s ' "-e MONGO_HOST=$P-db" "-e MONGO_USER=root"
    if [ "${2:-}" = wrong ]; then
      printf '%s ' "-e MONGO_PASSWORD=wrong"
    else
      printf '%s ' "-e MONGO_PASSWORD_FILE=/run/secrets/db_password"
    fi
  fi
}
# a container of the image on the test network, with the secrets mounted
img_net() {
  docker run --rm --network "$P-net" -v "$P-secrets:/run/secrets:ro" \
    -e AWS_ACCESS_KEY_ID=test -e "AWS_SECRET_ACCESS_KEY=$S3_SECRET" -e AWS_DEFAULT_REGION=us-east-1 \
    "$@"
}
aws_s3() { img_net "$IMAGE" aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }
# $1 label, $2 backup volume, extra docker run flags after: run /backup.sh once
run_backup() {
  _label="$1"; _vol="$2"; shift 2
  (
    set -f
    # shellcheck disable=SC2046
    docker run --rm "$@" --network "$P-net" -v "$_vol:/backups" -v "$P-secrets:/run/secrets:ro" \
      $(db_env "$_label") $(s3_env "$_label" 3) "$IMAGE" /backup.sh
  )
}

# data fingerprint: row count and a hash over the rows
fp_pg() {
  docker exec "$1" psql -At -U postgres -d app -c \
    "SELECT count(*) || ':' || md5(string_agg(id || ',' || name || ',' || created, ';' ORDER BY id)) FROM items"
}
fp_mongo_js="const d=db.items.find().sort({_id:1}).toArray(); print(d.length + ':' + require('crypto').createHash('sha256').update(EJSON.stringify(d)).digest('hex'))"
fp_src() {
  if [ "$KIND" = pg ]; then
    cap fp_pg "$P-db"
  else
    cap docker exec "$P-db" mongosh --quiet -u root -p "$DB_PASS" --authenticationDatabase admin app --eval "$fp_mongo_js"
  fi
}
fp_restored() {
  if [ "$KIND" = pg ]; then
    cap fp_pg "$P-db2"
  else
    cap docker exec "$P-db2" mongosh --quiet app --eval "$fp_mongo_js"
  fi
}

# ---- checks that run inside a container of the image under test ----
CHECK_LOCAL=$(cat <<'EOF'
set -eu
cd /backups
for db in $DBS; do
  n=0; f=""
  for x in last/"$db"-[0-9]*"$SUFFIX"; do
    [ -e "$x" ] || continue
    n=$((n + 1)); f="$x"
  done
  [ "$n" -eq 1 ] || { echo "$db: expected one file in last/, found $n" >&2; exit 1; }
  base=${f#last/}
  stamp=${base#"$db"-}; stamp=${stamp%"$SUFFIX"}
  day=${stamp%-*}
  month=${day%??}
  week=$(date -d "$day" +%G%V)
  for p in "daily/$db-$day$SUFFIX" "weekly/$db-$week$SUFFIX" "monthly/$db-$month$SUFFIX"; do
    [ -f "$p" ] || { echo "missing $p" >&2; exit 1; }
    [ "$p" -ef "$f" ] || { echo "$p is not a hard link of $f" >&2; exit 1; }
  done
  [ "$(stat -c %h "$f")" -eq 4 ] || { echo "$f: expected 4 links" >&2; exit 1; }
  [ "$(stat -c %u "$f")" = "$EXPECT_UID" ] || { echo "$f: owner is not uid $EXPECT_UID" >&2; exit 1; }
  if [ -n "${GZIP_CHECK:-}" ]; then gzip -t "$f" || { echo "$f is not a valid gzip file" >&2; exit 1; }; fi
  for d in last daily weekly monthly; do
    l="$d/$db-latest$SUFFIX"
    if [ "$LATEST" = symlink ]; then
      [ -L "$l" ] || { echo "$l is not a symlink" >&2; exit 1; }
      case "$d" in
        last) want="$base" ;;
        daily) want="$db-$day$SUFFIX" ;;
        weekly) want="$db-$week$SUFFIX" ;;
        monthly) want="$db-$month$SUFFIX" ;;
      esac
      [ "$(readlink "$l")" = "$want" ] || { echo "$l points to $(readlink "$l"), not $want" >&2; exit 1; }
    else
      { [ ! -e "$l" ] && [ ! -L "$l" ]; } || { echo "$l must not exist" >&2; exit 1; }
    fi
  done
done
if [ -n "$(find /backups -name '*.partial' | head -n 1)" ]; then
  echo "leftover .partial files" >&2; exit 1
fi
echo LOCAL-OK
EOF
)
CHECK_REMOTE=$(cat <<'EOF'
set -eu
AWS_SECRET_ACCESS_KEY=$(cat /run/secrets/aws_secret); export AWS_SECRET_ACCESS_KEY
s3() { aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }
keys() { s3 ls --recursive "s3://$1/$LABEL/" | awk '{print $4}' | sed "s|^$LABEL/||" | sort; }
cd /backups
# aws s3 sync follows symlinks; the encrypted staging only holds regular files
find -L . -type f | sed 's|^\./||' | sort > /tmp/l_plain
find . -type f | sed 's|^\./||; s|$|.gpg|' | sort > /tmp/l_gpg
find . -type f | sed 's|^\./||; s|$|.enc|' | sort > /tmp/l_enc
keys hot > /tmp/r_plain
keys enc > /tmp/r_gpg
keys encssl > /tmp/r_enc
for k in plain gpg enc; do
  [ -s "/tmp/l_$k" ] || { echo "no local files for $k" >&2; exit 1; }
  diff "/tmp/l_$k" "/tmp/r_$k" || { echo "bucket contents differ for the $k destination (< local, > remote)" >&2; exit 1; }
done
echo REMOTE-OK
EOF
)
CHECK_DECRYPT=$(cat <<'EOF'
set -eu
AWS_SECRET_ACCESS_KEY=$(cat /run/secrets/aws_secret); export AWS_SECRET_ACCESS_KEY
s3() { aws --endpoint-url "$S3_ENDPOINT" s3 "$@" --only-show-errors; }
for db in $DBS; do
  f=""
  for x in /backups/last/"$db"-[0-9]*"$SUFFIX"; do f="${x#/backups/}"; done
  s3 cp "s3://hot/$LABEL/$f" /tmp/plain
  cmp /tmp/plain "/backups/$f" || { echo "plain download of $f differs" >&2; exit 1; }
  rm -f /tmp/x /tmp/y
  s3 cp "s3://enc/$LABEL/$f.gpg" /tmp/x.gpg
  GNUPGHOME=$(mktemp -d) gpg --batch --yes --quiet --pinentry-mode loopback \
    --passphrase-file /run/secrets/enc_pass -o /tmp/x -d /tmp/x.gpg
  cmp /tmp/x "/backups/$f" || { echo "gpg-decrypted $f differs" >&2; exit 1; }
  s3 cp "s3://encssl/$LABEL/$f.enc" /tmp/y.enc
  openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/run/secrets/enc_pass -in /tmp/y.enc -out /tmp/y
  cmp /tmp/y "/backups/$f" || { echo "openssl-decrypted $f differs" >&2; exit 1; }
  cp /tmp/x "/work/$db$SUFFIX"
done
echo DECRYPT-OK
EOF
)

# $1 label, $2 backup volume, $3 expected owner uid of the dump files
verify() {
  _label="$1"; _vol="$2"; _uid="$3"
  _gz=""
  [ "$KIND" = pg ] && _gz=1
  _o=$(docker run --rm -v "$_vol:/backups:ro" \
    -e "DBS=$DBS" -e "SUFFIX=$SUFFIX" -e "LATEST=$LATEST" -e "EXPECT_UID=$_uid" -e "GZIP_CHECK=$_gz" \
    "$IMAGE" sh -c "$CHECK_LOCAL" 2>&1) || fail "$_label: local layout check: $_o"
  log "$_label: $_o"
  _o=$(img_net -v "$_vol:/backups:ro" -e "S3_ENDPOINT=$S3_ENDPOINT" -e "LABEL=$_label" \
    "$IMAGE" sh -c "$CHECK_REMOTE" 2>&1) || fail "$_label: bucket check: $_o"
  log "$_label: $_o"
  _o=$(img_net -v "$_vol:/backups:ro" -v "$P-work:/work" -e "S3_ENDPOINT=$S3_ENDPOINT" -e "LABEL=$_label" \
    -e "DBS=$DBS" -e "SUFFIX=$SUFFIX" "$IMAGE" sh -c "$CHECK_DECRYPT" 2>&1) || fail "$_label: download/decrypt check: $_o"
  log "$_label: $_o"
  # restore into the second database and compare the data
  if [ "$KIND" = pg ]; then
    docker exec "$P-db2" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
      -c 'DROP DATABASE IF EXISTS app' -c 'CREATE DATABASE app' >/dev/null || fail "$_label: cannot reset the restore database"
    docker run --rm --network "$P-net" -v "$P-work:/work" -e "PGPASSWORD=$DB_PASS" "$IMAGE" \
      sh -c 'gunzip -c /work/app.sql.gz | psql -v ON_ERROR_STOP=1 -q -h "$1" -U postgres -d app' sh "$P-db2" \
      >/dev/null || fail "$_label: restore failed"
  else
    docker run --rm --network "$P-net" -v "$P-work:/work" "$IMAGE" \
      mongorestore --host "$P-db2" --archive=/work/all.archive.gz --gzip --nsInclude='app.*' --drop --quiet \
      || fail "$_label: restore failed"
  fi
  _fp=$(fp_restored) || fail "$_label: cannot read the restored data"
  [ "$_fp" = "$FP_SRC" ] || fail "$_label: restored data differs (source '$FP_SRC', restored '$_fp')"
  log "$_label: restore OK ($_fp)"
  if [ "$KIND" = pg ]; then
    _hl=$(docker logs "$P-hook" 2>&1) || true
    case "$_hl" in *"url:/pre-$_label"*) ;; *) fail "$_label: no pre-backup webhook call" ;; esac
    case "$_hl" in *"url:/post-$_label"*) ;; *) fail "$_label: no post-backup webhook call" ;; esac
  fi
}

# ---- T1 image facts ----
log "T1 image facts"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found"
[ "$(cap docker run --rm "$IMAGE" id -u)" = 0 ] || fail "default user is not root"
docker run --rm "$IMAGE" sh -c 'test -x /usr/local/bin/go-cron && aws --version' >/dev/null 2>&1 || fail "go-cron or aws missing"
if [ "$KIND" = pg ]; then
  _v=$(cap docker run --rm "$IMAGE" pg_dump --version) || fail "pg_dump missing"
  case "$_v" in *"(PostgreSQL) $VERSION."*) ;; *) fail "pg_dump is '$_v', expected major $VERSION" ;; esac
  [ "$(cap docker run --rm --user postgres:postgres "$IMAGE" id -u)" = 999 ] || fail "postgres user is not uid 999"
  _h=$(cap docker run --rm "$IMAGE" run-parts --test /hooks | tr '\n' ' ')
  [ "$_h" = "/hooks/00-webhook /hooks/post-backup" ] || fail "unexpected hooks: $_h"
else
  docker run --rm "$IMAGE" sh -c 'mongodump --version && mongorestore --version' >/dev/null 2>&1 || fail "mongodump/mongorestore missing"
  # shellcheck disable=SC2016  # $t expands inside the container
  _x=$(cap docker run --rm "$IMAGE" sh -c 'for t in bsondump mongoexport mongoimport mongostat mongotop mongofiles; do command -v $t; done; true')
  [ -z "$_x" ] || fail "unexpected Database Tools in the image: $_x"
  _h=$(cap docker run --rm "$IMAGE" run-parts --test /hooks | tr '\n' ' ')
  [ "$_h" = "/hooks/post-backup" ] || fail "unexpected hooks: $_h"
fi

# ---- T2 s3-sync --list ----
log "T2 s3-sync --list"
_l=$(cap docker run --rm -e S3_BUCKET=hot -e S3_BUCKET_2=dr -e 'S3_SCHEDULE_2=0 4 * * 0' "$IMAGE" s3-sync --list) || fail "s3-sync --list failed"
_want=$(printf 'primary\thot\tafter-backup\n2\tdr\t- schedule="0 4 * * 0"')
[ "$_l" = "$_want" ] || fail "s3-sync --list printed: $_l"

# ---- T3 startup rejection of unparseable cron specs ----
log "T3 bad cron specs"
docker run -d --name "$P-bad1" -e S3_BUCKET=hot -e 'S3_SCHEDULE=not a cron' "$IMAGE" >/dev/null || fail "cannot start bad1"
docker run -d --name "$P-bad2" -e 'SCHEDULE=every day' -e VALIDATE_ON_START=FALSE "$IMAGE" >/dev/null || fail "cannot start bad2"
exited() { [ "$(docker inspect -f '{{.State.Status}}' "$1")" = exited ]; }
for _c in bad1 bad2; do
  retry 30 exited "$P-$_c" || fail "$_c did not exit on an invalid cron spec"
  _rc=$(cap docker inspect -f '{{.State.ExitCode}}' "$P-$_c")
  [ "$_rc" != 0 ] || fail "$_c exited 0 on an invalid cron spec"
done
_lg=$(docker logs "$P-bad1" 2>&1) || true
case "$_lg" in *"invalid S3_SCHEDULE"*) ;; *) fail "bad1 did not log 'invalid S3_SCHEDULE'" ;; esac
_lg=$(docker logs "$P-bad2" 2>&1) || true
case "$_lg" in *"invalid SCHEDULE"*) ;; *) fail "bad2 did not log 'invalid SCHEDULE'" ;; esac

# ---- T4 infrastructure ----
log "T4 starting the S3 server and the database"
docker network create "$P-net" >/dev/null || fail "cannot create the network"
docker volume create "$P-secrets" >/dev/null
docker volume create "$P-work" >/dev/null
docker run --rm -v "$P-secrets:/s" "$IMAGE" sh -c \
  'printf %s "$1" > /s/db_password; printf %s "$2" > /s/aws_secret; printf %s "$3" > /s/enc_pass; chmod 0444 /s/*' \
  sh "$DB_PASS" "$S3_SECRET" "$ENC_PASS" || fail "cannot write the secrets"
docker run -d --name "$P-s3" --network "$P-net" "$E2E_S3_IMAGE" server -s3 -dir=/data -ip="$P-s3" >/dev/null || fail "cannot start the S3 server"
retry 60 aws_s3 ls || fail "the S3 server did not come up"
for _b in hot enc encssl; do
  aws_s3 mb "s3://$_b" >/dev/null || fail "cannot create bucket $_b"
done
if [ "$KIND" = pg ]; then
  docker run -d --name "$P-hook" --network "$P-net" "$E2E_HOOK_IMAGE" httpd -f -vv -p 8080 >/dev/null || fail "cannot start the webhook receiver"
  for _d in db db2; do
    docker run -d --name "$P-$_d" --network "$P-net" -e "POSTGRES_PASSWORD=$DB_PASS" -e POSTGRES_DB=app "postgres:$VERSION" >/dev/null || fail "cannot start $_d"
  done
  for _d in db db2; do
    retry 90 docker exec "$P-$_d" pg_isready -h 127.0.0.1 -U postgres || fail "$_d did not come up"
  done
else
  docker run -d --name "$P-db" --network "$P-net" "mongo:$VERSION" --auth >/dev/null || fail "cannot start db"
  docker run -d --name "$P-db2" --network "$P-net" "mongo:$VERSION" >/dev/null || fail "cannot start db2"
  for _d in db db2; do
    retry 90 docker exec "$P-$_d" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' || fail "$_d did not come up"
  done
  docker exec "$P-db" mongosh --quiet admin --eval "db.createUser({user:'root',pwd:'$DB_PASS',roles:['root']})" >/dev/null || fail "cannot create the mongo root user"
fi

# ---- T5 seed ----
log "T5 seeding"
if [ "$KIND" = pg ]; then
  docker exec "$P-db" psql -v ON_ERROR_STOP=1 -q -U postgres -d app \
    -c "CREATE TABLE items (id integer PRIMARY KEY, name text NOT NULL, created timestamptz NOT NULL)" \
    -c "INSERT INTO items SELECT g, 'item-' || g, timestamptz '2026-01-01 00:00:00+00' + g * interval '1 minute' FROM generate_series(1, 1000) g" \
    -c "CREATE DATABASE app2" || fail "cannot seed app"
  docker exec "$P-db" psql -v ON_ERROR_STOP=1 -q -U postgres -d app2 \
    -c "CREATE TABLE t2 (id integer)" -c "INSERT INTO t2 SELECT generate_series(1, 10)" || fail "cannot seed app2"
else
  docker exec "$P-db" mongosh --quiet -u root -p "$DB_PASS" --authenticationDatabase admin app --eval \
    "const d=[]; for (let i=1;i<=1000;i++) d.push({_id:i, name:'item-'+i, n:i*2}); db.items.insertMany(d); db.getSiblingDB('app2').t2.insertMany([{_id:1},{_id:2}]);" >/dev/null || fail "cannot seed the database"
fi
FP_SRC=$(fp_src) || fail "cannot fingerprint the source data"
case "$FP_SRC" in 1000:*) ;; *) fail "unexpected source fingerprint '$FP_SRC'" ;; esac

# ---- T6 backup as root ----
log "T6 backup as root"
docker volume create "$P-bk-root" >/dev/null
run_backup root "$P-bk-root" || fail "root backup failed"
verify root "$P-bk-root" 0

# ---- T7 backup as a non-root user ----
log "T7 backup as $E2E_USER"
docker volume create "$P-bk-user" >/dev/null
# the mkdir keeps the volume non-empty: Docker resets the owner of an empty volume
# to the image's /backups (root) every time it is mounted
docker run --rm -v "$P-bk-user:/backups" "$IMAGE" sh -c 'mkdir -p /backups/last && chown -R "$1" /backups' sh "$E2E_USER" || fail "cannot chown the volume"
run_backup user "$P-bk-user" --user "$E2E_USER" || fail "backup under --user $E2E_USER failed"
verify user "$P-bk-user" "${E2E_USER%%:*}"

# ---- T8 service path ----
log "T8 default command (scheduler + healthcheck)"
docker volume create "$P-bk-svc" >/dev/null
(
  set -f
  # shellcheck disable=SC2046
  docker run -d --name "$P-svc" --network "$P-net" -v "$P-bk-svc:/backups" -v "$P-secrets:/run/secrets:ro" \
    $(db_env svc) $(s3_env svc) -e 'SCHEDULE=@every 1h' -e BACKUP_ON_START=TRUE -e 'S3_SCHEDULE_2=0 4 * * 0' "$IMAGE" >/dev/null
) || fail "cannot start the service container"
first_run_done() {
  case "$(docker exec "$P-svc" curl -sS http://localhost:8080/)" in *'"ExitTime": "2'*) return 0 ;; *) return 1 ;; esac
}
retry 180 first_run_done || fail "the first scheduled backup did not finish"
docker exec "$P-svc" curl -fsS -o /dev/null http://localhost:8080/ || fail "healthcheck endpoint reports a failed run"
_lg=$(docker logs "$P-svc" 2>&1) || true
case "$_lg" in *"destination 2: scheduling S3 sync on '0 4 * * 0'"*) ;; *) fail "no scheduler for destination 2 in the logs" ;; esac
_n=$(aws_s3 ls --recursive s3://hot/svc/last/ 2>/dev/null | wc -l)
[ "$_n" -ge 1 ] || fail "destination 1 has no objects after the first backup"
_n=$(aws_s3 ls --recursive s3://enc/svc/ 2>/dev/null | wc -l)
[ "$_n" -eq 0 ] || fail "scheduled destination 2 was synced after the backup"
docker exec "$P-svc" s3-sync --dest 2 || fail "s3-sync --dest 2 failed"
_keys=$(aws_s3 ls --recursive s3://enc/svc/ 2>/dev/null | awk '{print $4}')
[ -n "$_keys" ] || fail "destination 2 has no objects after s3-sync --dest 2"
for _k in $_keys; do
  case "$_k" in *.gpg) ;; *) fail "unencrypted key in the gpg bucket: $_k" ;; esac
done
docker rm -f "$P-svc" >/dev/null 2>&1 || true

# ---- T9 failure path ----
log "T9 failing backup"
docker volume create "$P-bk-fail" >/dev/null
(
  set -f
  # shellcheck disable=SC2046
  docker run --rm --network "$P-net" -v "$P-bk-fail:/backups" -v "$P-secrets:/run/secrets:ro" \
    $(db_env fail wrong) $(s3_env fail 3) "$IMAGE" /backup.sh >/dev/null 2>&1
) && fail "a backup with a wrong password exited 0"
_p=$(cap docker run --rm -v "$P-bk-fail:/backups:ro" "$IMAGE" find /backups -name '*.partial')
[ -z "$_p" ] || fail "leftover partial files after a failed backup: $_p"
if [ "$KIND" = pg ]; then
  _hl=$(docker logs "$P-hook" 2>&1) || true
  case "$_hl" in *"url:/pre-fail"*) ;; *) fail "no pre-backup webhook call in the failure run" ;; esac
  case "$_hl" in *"url:/error-fail"*) ;; *) fail "no error webhook call in the failure run" ;; esac
  case "$_hl" in *"url:/post-fail"*) fail "post-backup webhook fired for a failed backup" ;; esac
fi

printf 'E2E PASS: %s %s (%s)\n' "$KIND" "$VERSION" "$IMAGE"
