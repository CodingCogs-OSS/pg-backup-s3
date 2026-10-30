# Technical debt

The images were hardened, not taken to zero findings (owner decision). Scanner: `anchore/grype:v0.121.0`, scans run on 2026-10-30 with the Grype database of that day. This file lists what remains and why.

## Vulnerability counts

Raw counts, no ignore file, Critical (C) / High (H), with the fixable subset:

| Image | Before (C / H) | Before, fixable | After (C / H) | After, fixable |
|---|---|---|---|---|
| `pg-backup-s3:17` (old, Debian 13.1 base) | 56 / 307 | 43 / 196 | | |
| `mongo-backup-s3:8.0` (old) | 7 / 38 per the brief; 21 / 119 rescanned the same day | 21 / 119 | | |
| `pg-backup-s3:14` | | | 1 / 0 | 1 / 0 |
| `pg-backup-s3:15` | | | 1 / 0 | 1 / 0 |
| `pg-backup-s3:16` | | | 1 / 0 | 1 / 0 |
| `pg-backup-s3:17` | | | 1 / 0 | 1 / 0 |
| `pg-backup-s3:18` | | | 1 / 0 | 1 / 0 |
| `mongo-backup-s3:latest` | | | 1 / 0 | 1 / 0 |

The old mongo image count grew from the brief's 7 / 38 to 21 / 119 because the Grype database gained Go advisories between the two scans.

Command:

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v //var/run/docker.sock:/var/run/docker.sock -v grype-db:/root/.cache/grype \
  anchore/grype:v0.121.0 <image> -o json -q
```

## Ignored fixable findings (.grype.yaml)

| ID | Severity | Package | Where | Why not fixed | What fixes it |
|---|---|---|---|---|---|
| CVE-2026-115557 | Critical | python 3.14.8 | `/usr/local/aws-cli/v2/*/dist/libpython3.14.so.1.0` (AWS CLI v2 bundle, all images) | The AWS CLI installer ships its own CPython; we install the latest AWS release unmodified. | An AWS CLI release bundling Python 3.14.10 or newer. The next scheduled build picks it up. |

## Other remaining Critical/High findings

None. Every remaining Critical/High finding has a fix and is in the table above.

## Other debt

- The Go builder is pinned to the 1.27 minor (`GO_VERSION`). Bump it when Go 1.28 ships. The bookworm builder is needed while the runtime is Ubuntu 24.04 (glibc).
- `MONGO_TOOLS_VERSION`/`MONGO_TOOLS_COMMIT`, `GOCRONVER`/`GOCRON_COMMIT`, the Grype image digest in the workflow and the test images (`chrislusf/seaweedfs:4.51`, `busybox:stable`) are bumped by hand. Dependabot covers only the actions.
- go-cron v0.0.11 is old and unmaintained upstream. Its healthcheck endpoint is unauthenticated and returns the last run's stdout/stderr.
- `docker/keys/aws-cli.asc` expires 2027-07-01. Refresh it from the AWS install docs before then (the build checks the primary-key fingerprint).
- Untagged per-arch manifests pushed by digest accumulate on Docker Hub.
- Directory-format dumps (`POSTGRES_EXTRA_OPTS=-Fd`): files inside an in-progress `.partial` directory aren't excluded by `s3-sync`.
- `valid_schedule` checks the field count only. A 5-field spec with out-of-range values still passes and go-cron then ignores it.
- GitHub disables the scheduled workflow after 60 days without repository activity. Accepted; re-enable steps are in the README.
- mongo-tools vendored dependencies are used as released. Findings in them are fixed only by a new tools release.
- Medium findings (about 83 to 86 per image, 3 fixable) are not gated.
