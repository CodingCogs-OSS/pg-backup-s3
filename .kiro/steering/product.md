# Product

This repo builds two Docker images that dump a database on a schedule, keep a rotated local copy (`last/`, `daily/`, `weekly/`, `monthly/` under `/backups`), and ship that copy to one or more S3-compatible buckets. Source: GitHub `CodingCogs-OSS/pg-backup-s3`. Images: Docker Hub `cc0funobit/*`. MIT licensed, maintained by codingcogs.org.

| Image | Database | Built on |
|---|---|---|
| `cc0funobit/pg-backup-s3:17` (also `:latest`) | PostgreSQL 17 | `prodrigestivill/postgres-backup-local:17`, which does the dumps and rotation |
| `cc0funobit/mongo-backup-s3:8.0` | MongoDB 8.0 | `ubuntu:24.04` plus this repo's `mongodump` scripts, which mimic the pg base image |

Both images share the same S3 layer:

- Destination #1 uses unsuffixed variables (`S3_BUCKET`, `AWS_ACCESS_KEY_ID`, ...). Each extra destination uses the same names with a numeric suffix (`S3_BUCKET_2`, ...). An empty suffixed value falls back to the unsuffixed one.
- Each destination has its own credentials, region, endpoint (AWS, Backblaze B2, MinIO), SSE, `--delete` mirroring, sync schedule and optional gpg/openssl encryption.
- Secrets can come from a `*_FILE` companion variable. The plain variable wins when both are set.

`README.md` is the user-facing reference for every variable and default.

## Guarantees to preserve

- The pg image stays a drop-in replacement for `postgres-backup-local:17`, and existing single-destination configs keep working.
- Backups may hold PII. Never log secrets or put them on a command line where `ps` can see them.
- Never damage the remote copy: skip a `--delete` sync when `BACKUP_DIR` has no files, never upload `*.partial` files, allow only one sync at a time, and make scheduled syncs wait for a running dump.
- Reject bad configuration at startup (for example an unparseable cron spec) rather than silently never syncing.
- When any destination fails, the run exits non-zero so the base image fires its `error` hooks.
