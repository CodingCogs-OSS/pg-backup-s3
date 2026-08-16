# pg-backup-s3

[![Docker Hub](https://img.shields.io/docker/pulls/cc0funobit/pg-backup-s3?logo=docker&label=Docker%20Hub)](https://hub.docker.com/r/cc0funobit/pg-backup-s3)
[![Image Size](https://img.shields.io/docker/image-size/cc0funobit/pg-backup-s3/17?logo=docker&label=image%20size)](https://hub.docker.com/r/cc0funobit/pg-backup-s3)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Scheduled PostgreSQL backups that are automatically synced to one or more S3
destinations, each on its own schedule, with optional password-based encryption.
It builds on the excellent
[`prodrigestivill/postgres-backup-local`](https://hub.docker.com/r/prodrigestivill/postgres-backup-local)
image and adds the AWS CLI, a `post-backup` hook, and a per-destination sync
scheduler, so every local dump is mirrored off-site without any extra moving
parts.

## Why

`postgres-backup-local` already handles scheduled `pg_dump` runs and rotation
(last / daily / weekly / monthly). This image keeps all of that and ships each
backup to S3, giving you durable off-site copies of databases that may contain
PII. You can fan the same backups out to several buckets (even across
providers), encrypt the off-site copies with a passphrase you control, and give
each bucket its own sync cadence instead of pushing to all of them after every
dump.

## Features

- Scheduled Postgres dumps with the familiar `last/daily/weekly/monthly` layout
- Fan-out to **multiple S3 destinations**, each with its own credentials,
  region, and endpoint (AWS S3, Backblaze B2, MinIO, …)
- **Per-destination sync schedule** (`S3_SCHEDULE[_N]`): keep a hot bucket in
  sync after every dump while a cold/DR bucket only receives a weekly push
- **Per-destination encryption** (off by default) via GPG or OpenSSL, so the
  off-site copy is protected by a passphrase only you hold
- Server-side encryption via `--sse aws:kms` (auto-disabled for non-AWS
  endpoints, still overridable)
- **File-based secrets** for `AWS_SECRET_ACCESS_KEY` and the encryption
  passphrase (plus `POSTGRES_PASSWORD_FILE` from the base image)
- AWS CLI v2, architecture-aware (amd64 + arm64)
- Drop-in replacement for `postgres-backup-local:17`

## Usage

A single destination behaves exactly like before:

```yaml
services:
  pg-backup:
    image: cc0funobit/pg-backup-s3:17
    environment:
      # postgres-backup-local settings
      POSTGRES_HOST: db
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
      SCHEDULE: "@daily"
      # S3 sync settings (used by the post-backup hook)
      S3_BUCKET: my-backup-bucket
      S3_PREFIX: pg-backups
      AWS_ACCESS_KEY_ID: ...
      AWS_SECRET_ACCESS_KEY: ...
      AWS_DEFAULT_REGION: eu-central-1
```

A fuller example with two destinations, file-based secrets, and encryption on
the primary target:

```yaml
services:
  pg-backup:
    image: cc0funobit/pg-backup-s3:17
    environment:
      # --- Postgres (base image) ---
      POSTGRES_HOST: db
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
      SCHEDULE: "@daily"

      # --- Destination #1: AWS S3, encrypted ---
      S3_BUCKET: primary-bucket
      S3_PREFIX: pg-backups
      AWS_DEFAULT_REGION: eu-central-1
      AWS_ACCESS_KEY_ID: AKIA...
      AWS_SECRET_ACCESS_KEY_FILE: /run/secrets/aws_secret_1
      ENCRYPTION_ENABLED: "true"
      ENCRYPTION_PASSPHRASE_FILE: /run/secrets/backup_pass

      # --- Destination #2: Backblaze B2, own keys + endpoint, unencrypted ---
      # Synced every Sunday at 04:00 instead of after every dump
      S3_BUCKET_2: dr-bucket
      S3_PREFIX_2: pg-backups
      S3_REGION_2: us-west-002
      S3_ENDPOINT_2: https://s3.us-west-002.backblazeb2.com
      S3_SCHEDULE_2: "0 4 * * 0"
      AWS_ACCESS_KEY_ID_2: 0021...
      AWS_SECRET_ACCESS_KEY_2_FILE: /run/secrets/aws_secret_2
      # S3_SSE_2 left unset -> defaults to none because an endpoint is set
    secrets:
      - pg_password
      - aws_secret_1
      - aws_secret_2
      - backup_pass

secrets:
  pg_password:   { file: ./secrets/pg_password }
  aws_secret_1:  { file: ./secrets/aws_secret_1 }
  aws_secret_2:  { file: ./secrets/aws_secret_2 }
  backup_pass:   { file: ./secrets/backup_pass }
```

## Configuration

### Destinations

Destination **#1** uses the unsuffixed variables (fully backward compatible).
Add more destinations by appending a numeric suffix `_2`, `_3`, … to the same
variable names. Each destination is independent: it has its own bucket,
credentials, region, endpoint, SSE, and encryption settings. Any per-destination
value left empty falls back to the unsuffixed value, which makes the unsuffixed
variables convenient shared defaults.

| Variable (and `_N` form)         | Default                 | Description                                                  |
|----------------------------------|-------------------------|--------------------------------------------------------------|
| `S3_BUCKET` / `S3_BUCKET_N`       | _(required)_            | Target bucket. Presence of `S3_BUCKET_N` defines destination N |
| `S3_PREFIX` / `S3_PREFIX_N`       | `pg-backups`            | Key prefix within the bucket                                 |
| `S3_REGION` / `S3_REGION_N`       | `AWS_DEFAULT_REGION`    | Region for that destination                                  |
| `S3_ENDPOINT` / `S3_ENDPOINT_N`   | _(none = AWS)_          | Custom S3 endpoint URL (Backblaze B2, MinIO, …)              |
| `S3_SSE` / `S3_SSE_N`             | `aws:kms` / none        | Server-side encryption. Defaults to `aws:kms` on AWS and to none when an endpoint is set. Set to `""` to force off |
| `S3_DELETE` / `S3_DELETE_N`       | `true`                  | Mirror local rotation by deleting remote objects that no longer exist locally. Set `false` for an append-only remote copy |
| `AWS_ACCESS_KEY_ID` / `_N`        | _(required)_            | Access key for that destination                              |
| `AWS_SECRET_ACCESS_KEY` / `_N`    | _(required)_            | Secret key for that destination (supports `_FILE`)           |
| `BACKUP_DIR`                      | `/backups`              | Local directory that gets synced to S3                       |

### Sync scheduling (per destination)

By default every destination is synced right after each dump, so all buckets
receive the same backup at the same time. Set `S3_SCHEDULE[_N]` on a destination
to take it out of that path and give it its own cadence instead: the image then
runs a small cron scheduler per scheduled destination and syncs it on that
schedule only.

| Variable (and `_N` form)     | Default                                | Description                                                            |
|------------------------------|----------------------------------------|------------------------------------------------------------------------|
| `S3_SCHEDULE` / `_N`         | _(none = sync after every backup)_     | Cron spec for this destination's sync. Same syntax as `SCHEDULE`: 5 (or 6, seconds first) fields, or a descriptor such as `@daily`, `@weekly`, `@every 6h`. Use `none` to opt a destination out of an inherited unsuffixed `S3_SCHEDULE` |
| `S3_SYNC_ON_BACKUP` / `_N`   | `true` without a schedule, else `false`| Sync this destination right after each dump. Set `true` alongside a schedule to do both |
| `S3_SYNC_ON_START` / `_N`    | `false`                                | A scheduled destination also syncs once at container start (like `BACKUP_ON_START`) |

Global knobs (not per destination):

| Variable                | Default             | Description                                                                 |
|-------------------------|---------------------|-----------------------------------------------------------------------------|
| `S3_SYNC_SCHEDULER`     | `true`              | Set `false` to skip starting the per-destination schedulers entirely         |
| `S3_SYNC_LOCK_WAIT`     | `1800`              | Seconds a sync waits for another sync to finish before skipping its run      |
| `S3_SYNC_BACKUP_WAIT`   | `300`               | Seconds a scheduled sync waits for an in-flight dump to finish              |
| `S3_SYNC_STATE_DIR`     | `/tmp/pg-backup-s3` | Where the sync lock and the "dump in progress" marker live                   |

Example: hot bucket after every dump, DR bucket every Sunday at 04:00, cold
archive daily plus once at start.

```yaml
environment:
  SCHEDULE: "@daily"

  S3_BUCKET: hot-bucket            # no S3_SCHEDULE -> synced after every dump

  S3_BUCKET_2: dr-bucket
  S3_SCHEDULE_2: "0 4 * * 0"       # weekly, decoupled from the dump schedule

  S3_BUCKET_3: cold-bucket
  S3_SCHEDULE_3: "@daily"
  S3_SYNC_ON_START_3: "true"
```

Notes:

- Scheduled syncs push whatever is in `BACKUP_DIR` at that moment, so a
  destination on a weekly schedule ships the dumps that survived local rotation
  (`BACKUP_KEEP_*`) until then. Keep local retention long enough to cover the
  gap between syncs.
- Syncs are serialized: only one destination is ever uploading at a time, and a
  scheduled sync waits for a running dump so it can't ship a half-written file.
- A destination with `S3_SYNC_ON_BACKUP=false` and no schedule is never synced;
  the hook logs a line saying so.
- Cron specs are evaluated in the container's timezone, so set `TZ` if you care
  about the exact hour. An unparseable spec fails the container at startup rather
  than silently never syncing.
- Scheduling needs the image's default command
  (`/usr/local/bin/pg-backup-s3-entrypoint`). If you override `command:` /
  `entrypoint:` in Compose, the schedulers never start and the hook warns about
  it on the next backup.
- To push on demand, regardless of schedules:
  `docker compose exec pg-backup s3-sync --all` (or `--dest 2` for one bucket).

### Encryption (per destination)

Encryption is **disabled by default**. Enable it per destination; when on, the
copy uploaded to that destination is encrypted with a passphrase, while the
local dumps stay as plain `.sql.gz`.

| Variable (and `_N` form)              | Default | Description                                   |
|---------------------------------------|---------|-----------------------------------------------|
| `ENCRYPTION_ENABLED` / `_N`           | `false` | Encrypt this destination's copy               |
| `ENCRYPTION_METHOD` / `_N`            | `gpg`   | `gpg` (AES-256) or `openssl` (AES-256-CBC)    |
| `ENCRYPTION_PASSPHRASE` / `_N`        | _(none)_| Passphrase; required when enabled (supports `_FILE`) |

Encrypted objects keep the original key layout with an added extension:
`.sql.gz.gpg` for GPG or `.sql.gz.enc` for OpenSSL.

### File-based secrets

Append `_FILE` to a variable to read its value from a file (handy for Docker /
Compose / Swarm secrets). Supported here:

- `AWS_SECRET_ACCESS_KEY_FILE` (and `AWS_SECRET_ACCESS_KEY_N_FILE`)
- `ENCRYPTION_PASSPHRASE_FILE` (and `ENCRYPTION_PASSPHRASE_N_FILE`)
- `POSTGRES_PASSWORD_FILE`, `POSTGRES_USER_FILE`, `POSTGRES_DB_FILE` — provided
  by the base image

If both the plain variable and its `_FILE` companion are set, the plain value
wins.

Standard `POSTGRES_*`, `SCHEDULE`, and rotation variables are inherited from the
base image — see its documentation for the full list.

## How it works

All the S3 logic lives in one script, `/usr/local/bin/s3-sync` (run
`docker compose exec pg-backup s3-sync --help` to see its full reference, or
`s3-sync --list` to print the destinations and how each one is triggered). It is
driven from two places:

- The bundled `post-backup` hook, which the base image runs after each dump. It
  syncs every destination that has no schedule (`s3-sync --immediate`).
- One `go-cron` scheduler per destination that has an `S3_SCHEDULE[_N]`, started
  by the image's default command before it hands over to the base image's
  `/init.sh`. Each scheduler runs `s3-sync --dest <id>` on its own cadence.

For an unencrypted destination the sync mirrors the local layout directly:

```sh
aws s3 sync "${BACKUP_DIR:-/backups}" "s3://${S3_BUCKET}/${S3_PREFIX:-pg-backups}" \
  --sse aws:kms \
  --delete \
  --only-show-errors
```

By default the sync runs with `--delete`, so the remote tracks local rotation
(old backups removed locally are removed from S3 too). Set `S3_DELETE=false` (or
`S3_DELETE_N=false`) to keep an append-only remote copy instead.

For an encrypted destination the current backup tree is rendered into a
temporary staging directory (encrypting each file), then synced with the same
flags so the remote stays in lockstep with local rotation and no stale
ciphertext is left behind. The staging directory is removed afterwards.

Before syncing, `s3-sync` checks that `BACKUP_DIR` actually contains files and
skips the destination otherwise, so a `--delete` run can never wipe the remote
copy from an empty source.

Each destination runs in its own subshell, so credentials and flags never leak
between targets. If any destination fails, the run exits non-zero (which makes
the base image treat that backup as failed and fire its `error` hooks).

Two guards keep concurrent syncs honest, both using files under
`S3_SYNC_STATE_DIR`:

- a `flock` mutex, so a scheduled sync and a post-backup sync never upload at
  the same time (a run that waits longer than `S3_SYNC_LOCK_WAIT` is skipped and
  logged; the next run catches up)
- a "dump in progress" marker written by the `pre-backup` hook and cleared by
  the `post-backup` / `error` hooks, so a scheduled sync waits (up to
  `S3_SYNC_BACKUP_WAIT`) for the dump to finish instead of shipping a
  half-written file

## Restoring an encrypted backup

Decrypt first, then restore as usual. GPG:

```bash
gpg --batch --pinentry-mode loopback --passphrase-file ./pass \
  -o app-20240101.sql.gz -d app-20240101.sql.gz.gpg
gunzip app-20240101.sql.gz
```

OpenSSL:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -pass file:./pass \
  -in app-20240101.sql.gz.enc -out app-20240101.sql.gz
gunzip app-20240101.sql.gz
```

## Building

The Dockerfile lives under `hooks/`, but the build context must be the
repository root so both `hooks/` (the run-parts hook) and `lib/` (`s3-sync` and
the entrypoint wrapper) are included:

```bash
docker build -f hooks/Dockerfile.pg-backup \
  -t cc0funobit/pg-backup-s3:17 \
  -t cc0funobit/pg-backup-s3:latest .
```

Multi-arch build and push:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -f hooks/Dockerfile.pg-backup \
  -t cc0funobit/pg-backup-s3:17 \
  -t cc0funobit/pg-backup-s3:latest \
  --push .
```

## Docker Hub

Prebuilt, multi-arch images are published to Docker Hub:

**https://hub.docker.com/r/cc0funobit/pg-backup-s3**

```bash
docker pull cc0funobit/pg-backup-s3:17
```

## Tags

- `17` — built against PostgreSQL 17 (matches `postgres:17` servers)
- `latest` — points at the current stable build

## Notes

- Make sure the `pg_dump` major version matches your server's major version.
- For AWS destinations, the IAM identity needs `s3:PutObject` / `s3:ListBucket`
  (and `s3:DeleteObject`, since destinations sync with `--delete` by default)
  on the target bucket, plus `kms:GenerateDataKey` on the KMS key when SSE is on.
- Store the encryption passphrase somewhere safe and separate from the backups —
  without it, encrypted backups cannot be restored.

## License

This project's hook scripts and Dockerfile are released under the
[MIT License](LICENSE).

Note that the published image bundles third-party software with its own terms:
[`prodrigestivill/postgres-backup-local`](https://github.com/prodrigestivill/docker-postgres-backup-local)
and the [AWS CLI](https://github.com/aws/aws-cli). Refer to their respective
licenses for those components.

---

Maintained by the team at [codingcogs.org](https://codingcogs.org) — notes and
deeper write-ups on database tooling and infrastructure live there.
