# Structure

```
docker/Dockerfile.pg-backup     pg image: ubuntu:24.04 + PGDG postgresql-client-<major> + AWS CLI, gpg, openssl, flock (PG_MAJOR build arg is required)
docker/Dockerfile.mongo-backup  mongo image: ubuntu:24.04 + mongodump/mongorestore (built from source), go-cron, AWS CLI
docker/versions.env             pg majors and mongo versions (last entry = latest) and image names; read by scripts/ and CI
docker/keys/                    PGP keys checked by the Dockerfiles (aws-cli.asc, pgdg.asc)
hooks/post-backup               run-parts hook for the pre-backup, post-backup and error actions ($1)
lib/s3-sync                     all S3 logic: destinations, sync modes, encryption, locking, guards
lib/backup-s3-entrypoint        default CMD of both images; starts per-destination sync schedulers
lib/pg/init.sh, env.sh, backup.sh  pg /init.sh, /env.sh, /backup.sh: port of postgres-backup-local (MIT)
lib/pg/hooks/00-webhook         pg-only webhook hook (WEBHOOK_* variables)
lib/pg/NOTICE                   upstream MIT notice, shipped in the pg image
lib/mongo/init.sh               mongo /init.sh: validate config, run /backup.sh on SCHEDULE via go-cron
lib/mongo/env.sh                mongo /env.sh: validate config and derive values; sourced by backup.sh
lib/mongo/backup.sh             mongo /backup.sh: one mongodump run, rotation and hook calls
scripts/build.sh                local builds from docker/versions.env
scripts/ci-matrix.sh            build and publish matrices and tags for CI
tests/e2e.sh                    end-to-end test of one image against one database version
.github/workflows/images.yml    CI: build, test, scan and publish twice a day
.github/dependabot.yml          keeps the pinned action SHAs current
.grype.yaml                     Grype ignore list for known residual findings
technical_debt.md               remaining vulnerabilities and other debt (kept in sync with .grype.yaml)
README.md                       user docs: variables, examples, restore, build, CI
```

## Install paths in the images

| Repo file | Image path |
|---|---|
| `lib/s3-sync` | `/usr/local/bin/s3-sync` |
| `lib/backup-s3-entrypoint` | `/usr/local/bin/pg-backup-s3-entrypoint` or `/usr/local/bin/mongo-backup-s3-entrypoint`. Its log tag comes from that name. |
| `hooks/*` | `/hooks/` |
| `lib/pg/{init,env,backup}.sh` | `/init.sh`, `/env.sh`, `/backup.sh` (pg only) |
| `lib/pg/hooks/00-webhook` | `/hooks/00-webhook` (pg only) |
| `lib/pg/NOTICE` | `/usr/share/doc/pg-backup-s3/NOTICE.postgres-backup-local` (pg only) |
| `lib/mongo/*.sh` | `/init.sh`, `/env.sh`, `/backup.sh` (mongo only) |

## Runtime flow

1. The entrypoint reads `s3-sync --list-scheduled` and starts one `go-cron -p 0` per scheduled destination, each running `s3-sync --dest <id>`. It then writes the `scheduler-active` marker and runs `exec /init.sh`.
2. `/init.sh` validates `SCHEDULE` and runs `/backup.sh` on it through go-cron.
3. `/backup.sh` calls `run-parts -a <action> /hooks`. On `pre-backup` the hook writes the `backup-in-progress` marker. On `post-backup` it clears the marker and runs `s3-sync --immediate`, which syncs every destination without a schedule. On `error` it clears the marker. The pg image's `00-webhook` runs first on each action.
4. `s3-sync` takes the `flock`, then runs `ship_one` for each destination in its own subshell so credentials don't leak between destinations. For encrypted destinations it encrypts each file into a temp staging dir (with a throwaway `GNUPGHOME` for gpg) and syncs that dir.

The lock and marker files (`sync.lock`, `backup-in-progress`, `scheduler-active`) live in `S3_SYNC_STATE_DIR` (under `/tmp`, so `--user` works).

## CI

`.github/workflows/images.yml` has three stages: `prepare` (runs `scripts/ci-matrix.sh`), `build` (one job per image and architecture on native runners: build and push by digest, `tests/e2e.sh`, Grype scan, upload of the tested digest) and `publish` (per variant: merge the two tested digests and apply the tags). `scripts/ci-matrix.sh` and the workflow must change together.

## Rules for changes

- `hooks/`, `lib/s3-sync` and `lib/backup-s3-entrypoint` ship in both images. Changes to them must work in both.
- `lib/pg/` and `lib/mongo/` share the `/init.sh`, `/env.sh`, `/backup.sh` layout and the `run-parts` hook calls, so the shared layer runs unchanged. Keep that contract. `lib/pg/` stays environment-compatible with `postgres-backup-local`.
- The entrypoint parses `s3-sync --list` (tab-separated `id`, `bucket`, `trigger`) and `--list-scheduled` (`<id> <on_start> <schedule>`, schedule last because it contains spaces). Change both sides together.
- Destination ids are `primary` (unsuffixed variables) and `N` (the `_N` suffix). `sfx_for` maps an id to its suffix.
- Hook file names may contain only letters, digits, `_` and `-`. `run-parts` silently skips other names, so files in `hooks/` get no `.sh` extension.
- Both dump scripts write `<file>.partial` and rename it when complete. `s3-sync` excludes `*.partial`.
- `.dockerignore` un-ignores `hooks`, `lib` and `docker/keys`. A new top-level folder the image needs must be un-ignored there.
- A variable or default can live in four places: the script logic, the script's header comment, the README tables and the Dockerfile `ENV`. Update every one that applies.
- A new version goes into `docker/versions.env` only; the scripts and the workflow derive everything from it.
- `.grype.yaml` and the "Ignored fixable findings" section of `technical_debt.md` list the same IDs.
