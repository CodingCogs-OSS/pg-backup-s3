# pg-backup-s3

[![Docker Hub](https://img.shields.io/docker/pulls/cc0funobit/pg-backup-s3?logo=docker&label=Docker%20Hub)](https://hub.docker.com/r/cc0funobit/pg-backup-s3)
[![Image Size](https://img.shields.io/docker/image-size/cc0funobit/pg-backup-s3/17?logo=docker&label=image%20size)](https://hub.docker.com/r/cc0funobit/pg-backup-s3)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Scheduled PostgreSQL backups that are automatically synced to Amazon S3 with
server-side KMS encryption. It builds on the excellent
[`prodrigestivill/postgres-backup-local`](https://hub.docker.com/r/prodrigestivill/postgres-backup-local)
image and adds the AWS CLI plus a `post-backup` hook, so every local dump is
mirrored off-site without any extra moving parts.

## Why

`postgres-backup-local` already handles scheduled `pg_dump` runs and rotation
(last / daily / weekly / monthly). This image keeps all of that and ships each
backup to S3 the moment it's written, giving you durable, encrypted, off-site
copies of databases that may contain PII.

## Features

- Scheduled Postgres dumps with the familiar `last/daily/weekly/monthly` layout
- Automatic `aws s3 sync` to your bucket after each backup
- Encryption at rest via `--sse aws:kms`
- AWS CLI v2, architecture-aware (amd64 + arm64)
- Drop-in replacement for `postgres-backup-local:17`

## Usage

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

### Environment variables (added by this image)

| Variable     | Default      | Description                            |
|--------------|--------------|----------------------------------------|
| `S3_BUCKET`  | _(required)_ | Target S3 bucket for backups           |
| `S3_PREFIX`  | `pg-backups` | Key prefix within the bucket           |
| `BACKUP_DIR` | `/backups`   | Local directory that gets synced to S3 |

Standard `POSTGRES_*`, `SCHEDULE`, and rotation variables are inherited from the
base image — see its documentation for the full list.

## How it works

After each scheduled dump, the base image runs the bundled `post-backup` hook,
which mirrors the local backup layout into S3:

```sh
aws s3 sync "${BACKUP_DIR:-/backups}" "s3://${S3_BUCKET}/${S3_PREFIX:-pg-backups}" \
  --sse aws:kms \
  --only-show-errors
```

This keeps your S3 copy in lockstep with the local `last/daily/weekly/monthly`
folders, including rotation deletes.

## Building

The Dockerfile lives under `hooks/`, but the build context must be the parent
directory so the `hooks/` folder is included:

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
- The IAM identity needs `s3:PutObject` / `s3:ListBucket` on the target bucket
  and `kms:GenerateDataKey` on the KMS key used for encryption.

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
