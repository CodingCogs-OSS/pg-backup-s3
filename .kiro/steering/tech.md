# Tech

## Stack

- POSIX `sh` scripts (`#!/bin/sh`, `set -eu`). `/bin/sh` is dash in both images (Debian and Ubuntu), so avoid bashisms such as arrays, `[[ ]]`, `source`, `pipefail`, `${var//a/b}` and `$'...'`.
- Docker images for `linux/amd64` and `linux/arm64`. No application language, package manager, test suite or CI.
- Tools in the images: AWS CLI v2 (official installer, unpinned), `go-cron` (cron runner plus healthcheck endpoint), `gnupg` and `openssl` (encryption), `flock` from `util-linux` (sync lock), `run-parts` (hooks), MongoDB Database Tools (mongo image only).
- Version pins:
  - The pg base tag `17` must match the server's Postgres major version.
  - Mongo Database Tools `100.19.0` is checked against per-arch SHA256 build args. Update both checksums when bumping it.
  - `GOCRONVER=v0.0.11` is the same go-cron the pg base image uses, so `SCHEDULE` and `S3_SCHEDULE` accept the same syntax in both images.
- Arch detection: the pg Dockerfile uses `uname -m`; the mongo Dockerfile uses `TARGETARCH` and falls back to `dpkg --print-architecture`.

## Shell conventions

- Every script opens with a comment header documenting usage and env vars. In `lib/s3-sync` this header is the `--help` text, printed until the first line without `#`, so keep it accurate and contiguous.
- There is no shared helper library. Each script defines the helpers it needs, such as `log()` (writes `[tag] message` to stderr) and `is_true()` (accepts `1|true|yes|on` in any case).
- Function-scoped variables get a leading underscore (`_v`, `_rc`) in place of `local`, which POSIX doesn't define.
- Indirect variable lookups use `eval`. Reuse the existing helpers: `getval` (per-destination value with fallback), `getsecret` (adds `*_FILE`) and `get_sse` in `s3-sync`, and `_env_read` in `lib/mongo/env.sh`.
- Build argument lists with `set -- "$@" ...`. Wrap intended word splitting of user input in `set -f` / `set +f` and mark it with `# shellcheck disable=SC2086`.
- Pass secrets through stdin, an env var or a `0600` file, never argv. Existing examples: gpg `--passphrase-fd 0`, openssl `-pass env:ENC_PASS`, and a mongodump `--config` file in a `0700` temp dir.
- Hook and startup steps that must never fail end in `2>/dev/null || true`.
- Shared scripts default to the pg values (`S3_PREFIX=pg-backups`, `S3_SYNC_STATE_DIR=/tmp/pg-backup-s3`). The mongo Dockerfile overrides them with `ENV`. Put image-specific defaults in the Dockerfile, not the scripts.

## Line endings and file modes

- Scripts must use LF. With CRLF the kernel looks for `/bin/sh\r` and fails with "No such file or directory". `.gitattributes` forces LF for `hooks/*`, `lib/**` and `*.sh`; a script elsewhere needs a new rule.
- Check line endings with `git ls-files --eol`. In this Git Bash, `grep -c $'\r'` matches every line and reports CRLF that isn't there.
- Git stores the scripts as `100644`. Each Dockerfile strips CR, runs `chmod +x` and checks syntax with `sh -n` on the scripts it copies. Add new scripts to those lists; the pg Dockerfile names each `sh -n` target explicitly.

## Common commands

Run from the repo root. The build context must be the root because the images copy `hooks/` and `lib/`; `.dockerignore` excludes everything else.

```bash
# Build
docker build -f docker/Dockerfile.pg-backup -t cc0funobit/pg-backup-s3:17 -t cc0funobit/pg-backup-s3:latest .
docker build -f docker/Dockerfile.mongo-backup -t cc0funobit/mongo-backup-s3:8.0 .

# Multi-arch build and push to Docker Hub. This publishes, so only run it when asked.
docker buildx build --platform linux/amd64,linux/arm64 -f docker/Dockerfile.pg-backup \
  -t cc0funobit/pg-backup-s3:17 -t cc0funobit/pg-backup-s3:latest --push .
docker buildx build --platform linux/amd64,linux/arm64 -f docker/Dockerfile.mongo-backup \
  -t cc0funobit/mongo-backup-s3:8.0 --push .

# Lint. shellcheck isn't installed locally, so run it in Docker.
for f in hooks/post-backup lib/s3-sync lib/backup-s3-entrypoint lib/mongo/*.sh; do
  echo "== $f"; docker run --rm -i koalaman/shellcheck:stable - < "$f"
done

# Offline smoke test of destination parsing (no AWS calls)
docker run --rm -e S3_BUCKET=hot -e S3_BUCKET_2=dr -e S3_SCHEDULE_2='0 4 * * 0' \
  cc0funobit/mongo-backup-s3:8.0 s3-sync --list
```

- No automated tests exist. Verify a change with a build (which runs `sh -n`), the lint loop and a smoke test.
- `lib/s3-sync` already has three shellcheck findings: SC2154 on `b` (assigned through `eval`) and SC2086 on `$dest_ids` and `$due` (splitting is intended). Don't add new ones.
- Inside a running container, `s3-sync --help` documents every mode, and `s3-sync --all` or `s3-sync --dest <id>` pushes on demand. Run a Mongo dump on demand with `/backup.sh`.
- Git Bash rewrites container paths such as `/backup.sh` into Windows paths. Prefix the command with `MSYS_NO_PATHCONV=1`.

## Commits

Conventional Commits with a scope and a capitalized imperative subject, followed by a body of `- Add ...` / `- Update ...` bullets. Examples: `feat(s3-sync): Add ...`, `docs(readme): ...`, `chore(init): ...`, `feat(docker,sync-scheduling): ...`.
