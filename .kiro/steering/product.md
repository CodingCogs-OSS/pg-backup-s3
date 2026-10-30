# Product

This repo builds two Docker images that dump a database on a schedule, keep a rotated local copy (`last/`, `daily/`, `weekly/`, `monthly/` under `/backups`), and ship that copy to one or more S3-compatible buckets. Source: GitHub `CodingCogs-OSS/pg-backup-s3`. Images: Docker Hub `cc0funobit/*`. MIT licensed, maintained by codingcogs.org.

| Image | Database | Built on |
|---|---|---|
| `cc0funobit/pg-backup-s3:{14,15,16,17,18}` (`latest` = 18) | PostgreSQL 14 to 18 | `ubuntu:24.04` + PGDG `postgresql-client-<major>` + `lib/pg/`, a port of the `postgres-backup-local` scripts (MIT) |
| `cc0funobit/mongo-backup-s3:{7.0,8.0,8.3,9.0}` (`latest` = 9.0) | MongoDB 7.0 to 9.0 (one image, all tags) | `ubuntu:24.04` + `mongodump`/`mongorestore` 100.20.0 built from source + `lib/mongo/` |

Every version tag also has an immutable `<version>-<UTC ISO 8601 basic timestamp>` tag (for example `17-20261030T031700Z`); `latest` has none. CI rebuilds, tests, scans and publishes everything at 03:17 and 15:17 UTC, on push to `main` and on demand.

Both images share the same S3 layer:

- Destination #1 uses unsuffixed variables (`S3_BUCKET`, `AWS_ACCESS_KEY_ID`, ...). Each extra destination uses the same names with a numeric suffix (`S3_BUCKET_2`, ...). An empty suffixed value falls back to the unsuffixed one.
- Each destination has its own credentials, region, endpoint (AWS, Backblaze B2, MinIO), SSE, `--delete` mirroring, sync schedule and optional gpg/openssl encryption.
- Secrets can come from a `*_FILE` companion variable. For `AWS_*` and `ENCRYPTION_*` the plain variable wins when both are set; for `POSTGRES_*` the `_FILE` value wins, as in `postgres-backup-local`.

`README.md` is the user-facing reference for every variable and default. `technical_debt.md` records the vulnerabilities that remain after hardening.

## Guarantees to preserve

- The pg image stays an environment-compatible drop-in for `postgres-backup-local:<major>`: same variables, defaults, file names, folder layout, hooks, webhooks, healthcheck and `/backup.sh`. Existing single-destination configs keep working.
- The default user stays root; `--user <uid>:<gid>` works in both images (documented in the README, covered by `tests/e2e.sh`).
- Nothing gets a public tag unless `tests/e2e.sh` passed on that exact digest. A scheduled run publishes tested images and then fails the run if the Grype gate found fixable Critical/High findings that are not in `.grype.yaml`.
- `.grype.yaml` and `technical_debt.md` stay in sync: one ignore entry per remaining fixable Critical/High, each pointing at `technical_debt.md`.
- Backups may hold PII. Never log secrets or put them on a command line where `ps` can see them.
- Never damage the remote copy: skip a `--delete` sync when `BACKUP_DIR` has no files, never upload `*.partial` files, allow only one sync at a time, and make scheduled syncs wait for a running dump.
- Reject bad configuration at startup (for example an unparseable cron spec in `SCHEDULE` or `S3_SCHEDULE`) rather than silently never running.
- When any destination fails, the run exits non-zero so the `error` hooks fire.
- Never push images from a workstation; CI publishes.
