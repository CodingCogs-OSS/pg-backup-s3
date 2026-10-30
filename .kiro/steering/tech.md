# Tech

## Stack

- POSIX `sh` scripts (`#!/bin/sh`, `set -eu`). `/bin/sh` is dash in both images (both are `ubuntu:24.04`), so avoid bashisms such as arrays, `[[ ]]`, `source`, `pipefail`, `${var//a/b}` and `$'...'`.
- Docker images for `linux/amd64` and `linux/arm64`. No application language and no package manager. Tests are `tests/e2e.sh` plus the CI workflow `.github/workflows/images.yml`.
- Tools in the images: AWS CLI v2 (official installer, unpinned, PGP-verified in a builder stage), `go-cron` (built from source; cron runner plus healthcheck endpoint), `gpg` + `gpg-agent` and `openssl` (encryption), `flock` from `util-linux` (sync lock), `run-parts` (hooks), PGDG `postgresql-client-<major>` (pg image), `mongodump` + `mongorestore` built from source (mongo image; no other Database Tools).
- Version pins:
  - `docker/versions.env` lists `PG_MAJORS` and `MONGO_VERSIONS`; the last entry of each list is also tagged `latest`. `scripts/build.sh` and `scripts/ci-matrix.sh` read it. The pg Dockerfile requires `--build-arg PG_MAJOR=<major>`.
  - `GO_VERSION=1.27` selects `golang:<v>-bookworm` for the builder stages. Bookworm's glibc (2.36) is older than Ubuntu 24.04's, so the cgo mongo tools run on the runtime image.
  - `GOCRONVER=v0.0.11` + `GOCRON_COMMIT` (same go-cron as `postgres-backup-local`, so `SCHEDULE` and `S3_SCHEDULE` accept the same syntax). Update both together.
  - `MONGO_TOOLS_VERSION=100.20.0` + `MONGO_TOOLS_COMMIT`. Update both together.
  - PGP key fingerprints `AWSCLI_KEY_FPR` and `PGDG_KEY_FPR` in the Dockerfiles, checked against the key files in `docker/keys/` (the AWS key expires 2027-07-01).
  - The Grype image digest in the workflow (`GRYPE_IMAGE`), the test images in `tests/e2e.sh` (`chrislusf/seaweedfs`, `busybox`) and the action SHAs. Dependabot covers only the actions.
- Arch detection: both Dockerfiles use `TARGETARCH` with a `dpkg --print-architecture` fallback; go-cron cross-compiles on `BUILDPLATFORM`.
- apt: HTTPS sources plus `Acquire::Retries "5"` in every stage. Ubuntu stages copy the CA bundle from the golang stage before their first `apt-get update`.

## Shell conventions

- Every script opens with a comment header documenting usage and env vars. In `lib/s3-sync` this header is the `--help` text, printed until the first line without `#`, so keep it accurate and contiguous.
- There is no shared helper library. Each script defines the helpers it needs, such as `log()` (writes `[tag] message` to stderr) and `is_true()` (accepts `1|true|yes|on` in any case). `valid_schedule` has three identical copies (`lib/backup-s3-entrypoint`, `lib/pg/init.sh`, `lib/mongo/init.sh`); change them together.
- Function-scoped variables get a leading underscore (`_v`, `_rc`) in place of `local`, which POSIX doesn't define.
- Indirect variable lookups use `eval`. Reuse the existing helpers: `getval` (per-destination value with fallback), `getsecret` (adds `*_FILE`) and `get_sse` in `s3-sync`, and `_env_read` in `lib/mongo/env.sh`.
- Build argument lists with `set -- "$@" ...`. Wrap intended word splitting of user input in `set -f` / `set +f` and mark it with `# shellcheck disable=SC2086`.
- Pass secrets through stdin, an env var or a `0600` file, never argv. Existing examples: gpg `--passphrase-fd 0`, openssl `-pass env:ENC_PASS`, a mongodump `--config` file in a `0700` temp dir, libpq `PGPASSWORD`, and the webhook URL on curl's stdin (`--config -`).
- `s3-sync` gives each encrypted destination a private temp dir with a throwaway `GNUPGHOME`, so gpg works under any `--user`.
- Hook and startup steps that must never fail end in `2>/dev/null || true`.
- Shared scripts default to the pg values (`S3_PREFIX=pg-backups`, `S3_SYNC_STATE_DIR=/tmp/pg-backup-s3`). The mongo Dockerfile overrides them with `ENV`. Put image-specific defaults in the Dockerfile, not the scripts.

## Line endings and file modes

- Scripts must use LF. With CRLF the kernel looks for `/bin/sh\r` and fails with "No such file or directory". `.gitattributes` forces LF for `hooks/*`, `lib/**`, `*.sh`, `docker/versions.env`, `docker/keys/*`, `scripts/**`, `tests/**` and `.github/**`; a script elsewhere needs a new rule.
- Check line endings with `git ls-files --eol`. In this Git Bash, `grep -c $'\r'` matches every line and reports CRLF that isn't there.
- Git stores the scripts as `100644`. Each Dockerfile strips CR, runs `chmod +x` and checks syntax with `sh -n` on the scripts it copies. Add new scripts to those lists; the pg Dockerfile names each `sh -n` target explicitly (including `/init.sh /env.sh /backup.sh /hooks/post-backup /hooks/00-webhook`).

## Common commands

Run from the repo root. The build context must be the root because the images copy `hooks/`, `lib/` and `docker/keys/`; `.dockerignore` excludes everything else.

```bash
# Build for the host architecture (versions come from docker/versions.env)
sh scripts/build.sh                 # every pg major and the mongo image
sh scripts/build.sh pg 18
sh scripts/build.sh mongo
# add flags with DOCKER_BUILD_FLAGS="--pull --no-cache"

# Publishing is done by CI only (.github/workflows/images.yml). Never push images from a workstation.

# End-to-end test (needs Docker only)
sh tests/e2e.sh pg cc0funobit/pg-backup-s3:18 18
sh tests/e2e.sh mongo cc0funobit/mongo-backup-s3:latest 9.0

# Lint. shellcheck isn't installed locally, so run it in Docker.
for f in hooks/post-backup lib/s3-sync lib/backup-s3-entrypoint lib/mongo/*.sh lib/pg/*.sh lib/pg/hooks/00-webhook tests/e2e.sh scripts/*.sh docker/versions.env; do
  docker run --rm -i koalaman/shellcheck:stable -s sh -f gcc - < "$f" | sed "s|^-:|$f:|"
done

# Workflow lint
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo" -w /repo rhysd/actionlint:latest -no-color
uvx zizmor .github/

# Vulnerability gate, as CI runs it (see GRYPE_IMAGE in the workflow for the pinned version)
MSYS_NO_PATHCONV=1 docker run --rm -v //var/run/docker.sock:/var/run/docker.sock -v grype-db:/root/.cache/grype -v "$(pwd -W):/work" -w /work \
  anchore/grype:v0.121.0 cc0funobit/pg-backup-s3:18 --config /work/.grype.yaml --only-fixed --fail-on high -o table

# Offline smoke test of destination parsing (no AWS calls)
docker run --rm -e S3_BUCKET=hot -e S3_BUCKET_2=dr -e S3_SCHEDULE_2='0 4 * * 0' \
  cc0funobit/mongo-backup-s3:latest s3-sync --list
```

- Verify a change with a build (which runs `sh -n`), the lint loop, `tests/e2e.sh` and, for workflow changes, actionlint and zizmor.
- `lib/s3-sync` already has three shellcheck findings: SC2154 on `b` (assigned through `eval`) and SC2086 on `$dest_ids` and `$due` (splitting is intended). Don't add new ones.
- Inside a running container, `s3-sync --help` documents every mode, and `s3-sync --all` or `s3-sync --dest <id>` pushes on demand. Run a dump on demand with `/backup.sh`.
- Git Bash rewrites container paths such as `/backup.sh` into Windows paths. Prefix the command with `MSYS_NO_PATHCONV=1`.
- Docker resets the owner of an empty named volume to the image's `/backups` (root) on every mount. When testing `--user`, put a folder in the volume before the `chown`.

## Commits

Conventional Commits with a scope and a capitalized imperative subject, followed by a body of `- Add ...` / `- Update ...` bullets. Examples: `feat(s3-sync): Add ...`, `docs(readme): ...`, `chore(init): ...`, `feat(docker,sync-scheduling): ...`.
