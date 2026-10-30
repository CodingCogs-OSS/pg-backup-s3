# Structure

```
docker/Dockerfile.pg-backup     pg image: base image + AWS CLI, gnupg, openssl, flock
docker/Dockerfile.mongo-backup  mongo image: ubuntu:24.04 + Database Tools, go-cron, AWS CLI
hooks/post-backup               run-parts hook for the pre-backup, post-backup and error actions ($1)
lib/s3-sync                     all S3 logic: destinations, sync modes, encryption, locking, guards
lib/backup-s3-entrypoint        default CMD of both images; starts per-destination sync schedulers
lib/mongo/init.sh               mongo /init.sh: validate config, run /backup.sh on SCHEDULE via go-cron
lib/mongo/env.sh                mongo /env.sh: validate config and derive values; sourced by backup.sh
lib/mongo/backup.sh             mongo /backup.sh: one mongodump run, rotation and hook calls
README.md                       user docs: variables, examples, restore, build
```

## Install paths in the images

| Repo file | Image path |
|---|---|
| `lib/s3-sync` | `/usr/local/bin/s3-sync` |
| `lib/backup-s3-entrypoint` | `/usr/local/bin/pg-backup-s3-entrypoint` or `/usr/local/bin/mongo-backup-s3-entrypoint`. Its log tag comes from that name. |
| `hooks/*` | `/hooks/` |
| `lib/mongo/*.sh` | `/init.sh`, `/env.sh`, `/backup.sh` (mongo only; the pg base image ships its own) |

## Runtime flow

1. The entrypoint reads `s3-sync --list-scheduled` and starts one `go-cron -p 0` per scheduled destination, each running `s3-sync --dest <id>`. It then writes the `scheduler-active` marker and runs `exec /init.sh`.
2. `/init.sh` runs `/backup.sh` on `SCHEDULE` through go-cron.
3. `/backup.sh` calls `run-parts -a <action> /hooks`. On `pre-backup` the hook writes the `backup-in-progress` marker. On `post-backup` it clears the marker and runs `s3-sync --immediate`, which syncs every destination without a schedule. On `error` it clears the marker.
4. `s3-sync` takes the `flock`, then runs `ship_one` for each destination in its own subshell so credentials don't leak between destinations. For encrypted destinations it encrypts each file into a temp staging dir and syncs that dir.

The lock and marker files (`sync.lock`, `backup-in-progress`, `scheduler-active`) live in `S3_SYNC_STATE_DIR`.

## Rules for changes

- `hooks/`, `lib/s3-sync` and `lib/backup-s3-entrypoint` ship in both images. Changes to them must work in both.
- `lib/mongo/` copies the pg base image's `/init.sh`, `/env.sh`, `/backup.sh` layout and its `run-parts` hook calls, so the shared layer runs unchanged. Keep that contract.
- The entrypoint parses `s3-sync --list` (tab-separated `id`, `bucket`, `trigger`) and `--list-scheduled` (`<id> <on_start> <schedule>`, schedule last because it contains spaces). Change both sides together.
- Destination ids are `primary` (unsuffixed variables) and `N` (the `_N` suffix). `sfx_for` maps an id to its suffix.
- Hook file names may contain only letters, digits, `_` and `-`. `run-parts` silently skips other names, so files in `hooks/` get no `.sh` extension.
- The mongo dump writes `<file>.partial` and renames it when complete. `s3-sync` excludes `*.partial`.
- A new top-level folder the image needs must be un-ignored in `.dockerignore`.
- A variable or default can live in four places: the script logic, the script's header comment, the README tables and the Dockerfile `ENV`. Update every one that applies.
