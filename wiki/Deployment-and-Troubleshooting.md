# Deployment and Troubleshooting

Watchdog is designed for a scheduler. Treat its configuration, binaries,
environment files, state directory, and output directories as an operational
security boundary.

## Docker deployment

Docker is an optional packaging and scheduling surface; native single-file,
systemd, and cron deployments remain supported. The production runtime image is
built from [`packaging/docker/Dockerfile`](../packaging/docker/Dockerfile).
This is distinct from the root `Dockerfile`, which belongs exclusively to the
GitHub Marketplace configuration-validation Action.

Copy the container-specific configuration, adapt its sample endpoint, and make
the persistent directory writable by the image's fixed non-root user:

```bash
cp packaging/docker/config.example.yaml config.yaml
mkdir -p state
sudo chown -R 10001:10001 state
docker compose -f docker-compose.example.yml run --rm watchdog validate
docker compose -f docker-compose.example.yml run --rm watchdog
```

The default Compose service mounts only `config.yaml` read-only and `state/` at
`/var/lib/watchdog`. The supplied configuration places state and the operational
log in that mounted location. Add an explicit mount when enabling history,
Prometheus textfile metrics, or a generated status page outside it. The image
runs as UID/GID `10001`, has a read-only root filesystem, drops all capabilities,
sets `no-new-privileges`, and gives only `/tmp` a small writable tmpfs. It does
not use privileged mode, host networking, host filesystem mounts, or the Docker
socket.

Container checks observe the container network and only filesystems deliberately
mounted into it. A disk check cannot see host capacity without a specific
read-only host mount, and `127.0.0.1` targets the Watchdog container rather
than the host. Host `systemctl` commands are unavailable. Docker CLI actions
need the separate socket profile below. A ClamAV check also needs an explicitly
mounted scan path and current virus definitions; neither is silently bundled as
host access.

The image is a one-shot job. Its `0`/`1`/`2` exit code is the monitoring result;
it is not a daemon or a scheduler. For example, a host cron can launch a fresh
cycle each minute:

```cron
* * * * * cd /srv/watchdog && /usr/bin/docker compose -f docker-compose.example.yml run --rm --no-deps watchdog
```

The container's `HEALTHCHECK` runs Watchdog's read-only `validate` command. It
checks the mounted configuration and required runtime dependencies, not the
monitored services. Consume the scheduled run's exit code plus Watchdog alerts,
metrics, and `status` output for service health. The entrypoint forwards stop
signals through the Watchdog process tree, including a running check command,
then waits for Watchdog's normal cleanup and preserves its exit code.

Secrets remain environment variables named by the configuration's `*_env`
fields. Do not bake them into an image or compose file. A one-off run can use a
protected Docker environment file:

```bash
docker run --rm \
  --env-file /etc/watchdog/notification.env \
  --volume "$PWD/config.yaml:/etc/watchdog/config.yaml:ro" \
  --volume "$PWD/state:/var/lib/watchdog" \
  ghcr.io/shellharbor/watchdog:<version> notify-test --channel all
```

For a future external scheduler or agent, the stable container interface is a
mounted `/etc/watchdog/config.yaml` (or `WATCHDOG_CONFIG`), deliberate output
mounts, secret environment variables, one command, and its exit status. No
agent implementation is required for this contract.

### Docker socket remediation is exceptional

The `watchdog-docker-actions` service is inactive unless the
`docker-actions` profile is selected. It uses the separately published
`-docker` image because that image alone includes the Docker CLI. Set the host
socket group ID explicitly before using it:

```bash
export WATCHDOG_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
docker compose -f docker-compose.example.yml \
  --profile docker-actions run --rm watchdog-docker-actions
```

Mounting `/var/run/docker.sock` gives the container control of the host Docker
daemon and can permit host-level compromise. Use a dedicated reviewed config,
least-privilege action policy, and a safer remote remediation path where
possible. The default service deliberately never receives this access.

### Image releases

Published GitHub Releases build GHCR images for `linux/amd64` and `linux/arm64`.
They receive full, minor, and major version aliases; `latest` is only moved by a
non-prerelease. A manually selected tag must already contain this distribution.
The Docker-enabled image uses the same aliases with a `-docker` suffix. OCI
labels, provenance, and an SBOM are attached during publication.
Docker Hub publication is optional and runs only when `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN` repository secrets are both configured; otherwise the GHCR
job proceeds independently.

## Systemd deployment

The installer provides `service-watchdog.service` and a one-minute
`service-watchdog.timer`. After installation:

```bash
sudo systemctl enable --now service-watchdog.timer
systemctl list-timers service-watchdog.timer
sudo systemctl status service-watchdog.service
sudo journalctl -u service-watchdog.service -n 100 --no-pager
```

Adjust `OnUnitActiveSec` in
[`packaging/systemd/service-watchdog.timer`](../packaging/systemd/service-watchdog.timer)
when a different frequency is appropriate. A service account must be able to
run all selected checks and actions; Docker remediation often requires socket
group access, while `systemctl` actions usually need a root timer or a narrowly
scoped sudo/polkit policy.

Store secrets in the protected environment file read by the unit:

```bash
sudo install -m 0600 /dev/null /etc/service-watchdog/environment
sudoedit /etc/service-watchdog/environment
sudo chmod 0600 /etc/service-watchdog/environment
```

Example contents:

```text
WATCHDOG_SMTP_PASSWORD=replace-with-the-real-password
WATCHDOG_TG_BOT_TOKEN=replace-with-the-real-token
```

## Cron deployment

Use cron only when it is the better fit for the host. Keep configuration and
secret environment variables restricted to the selected scheduler user.

```cron
WATCHDOG_SMTP_PASSWORD=replace-with-the-real-password

* * * * * /opt/service-watchdog/service-watchdog.sh -c /etc/service-watchdog/config.yaml >> /var/log/service-watchdog/cron.log 2>&1
```

To run every five minutes:

```cron
*/5 * * * * /opt/service-watchdog/service-watchdog.sh -c /etc/service-watchdog/config.yaml >> /var/log/service-watchdog/cron.log 2>&1
```

The global non-blocking lock means an overlapping scheduled execution is
skipped rather than queued. Configure check/action timeouts and parallelism so
the expected run duration is comfortably below the schedule interval.

## Configuration read performance

At startup, Watchdog snapshots simple configuration values, node types, lengths,
and map entry order in memory. The snapshot is rebuilt after template expansion
and is inherited by parallel check workers, so normal runs avoid repeatedly
starting `yq` for the same scalar settings. No cache file is written, and each
one-shot execution reads the current configuration afresh.

Simple dotted paths and numeric array indexes are served from this snapshot;
complex expressions retain the safe `yq` fallback.

Complex YAML expressions, including unusual quoted map keys, keep using `yq`
directly. This fallback preserves configuration semantics rather than trading
correctness for an optimization.

## Validate configuration in GitHub Actions

The repository includes a self-contained Docker Action for pull-request and
deployment validation. It runs only `service-watchdog.sh validate`; it does not
perform health checks, remediation, notification delivery, or create runtime
files.

```yaml
name: Validate Watchdog configuration

on: [pull_request, push]

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: shellharbor/watchdog@v1
        with:
          config: monitoring/watchdog.yaml
```

`config` is relative to the checked-out workspace; paths outside it are
rejected. The image includes yq v4 plus Watchdog's optional validation tools.
It returns `0` for a valid file and `2` for a configuration error. An
enforce-mode action policy that points at executables unique to a production
host must also be validated on that target host before deployment.

## Developing the monitor source

Production deployments still use the self-contained `service-watchdog.sh` file.
Contributors edit the ordered files in `lib/watchdog/`, regenerate the
distribution, and verify that it is current before submitting a change:

```bash
bash ./scripts/build-watchdog.sh
bash ./scripts/build-watchdog.sh --check
```

The installer and systemd unit do not need the module directory at runtime.

## Safe release checklist

Before enabling a changed configuration in production:

```bash
# 1. Static configuration and environment/dependency checks.
bash ./service-watchdog.sh validate -c ./config.yaml

# 2. Run health checks without state changes or side effects.
sudo bash ./service-watchdog.sh -c ./config.yaml --dry-run

# 3. Verify channels without manufacturing an outage.
bash ./service-watchdog.sh notify-test -c ./config.yaml --channel all

# 4. Review saved runtime status after the first normal run.
bash ./service-watchdog.sh status -c ./config.yaml --all
```

Do not use `--dry-run` as a notification test: dry run deliberately sends no
notifications. Use `notify-test`, whose outgoing content carries `[TEST]`.

## Diagnose common outcomes

| Symptom | Likely cause and next step |
| --- | --- |
| Exit `2` before checks start | Run `validate`; correct the named YAML path, missing secret variable, unavailable optional tool, timezone, directory, dependency name, or action policy entry. |
| No alert from a failed service | Confirm a transition actually occurred; repeated failure alerts are suppressed. Check enabled channels, the service's optional `notify.channels`, environment variables, maintenance status, and the operational log. Use `notify-test -s SERVICE` to see `not routed` channels. |
| `status` says `unknown` | The service has no state file yet. Run one successful normal monitoring pass, then inspect again. |
| Action never runs | Look for cooldown/backoff, maintenance, flapping, manual intervention, circuit-open, dependency failure, or a denied remediation policy. `status` exposes many of these blockers. |
| A consumer is `dependency_failed` | Repair its required upstream service first. The downstream health check intentionally did not run. |
| A command is rejected | Commands must be argv arrays. In `enforce` policy mode, use an absolute, real executable and exactly allowlist the action vector. |
| A security check fails validation | Install/permit the optional tool only for the enabled feature (`clamscan`, `journalctl`, `ss`/`netstat`, or `sqlite3` for SQLite history). |
| A schedule seems to do nothing | Inspect timer/cron logs, check the lock for an overlapping run, and confirm the scheduler account can read the config and write runtime paths. |

Never paste webhook URLs, SMTP passwords, tokens, or private incident data into issue reports. Logs and state are designed not to persist secret values, but configuration and command output still deserve restricted permissions.

## Run project checks before contributing

The project uses syntax checks, ShellCheck, schema validation, and focused Bash
regression tests. Run the narrowest relevant test first, then broader coverage:

```bash
bash ./scripts/build-watchdog.sh --check
bash -n service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh lib/watchdog/*.sh tests/*.sh
bash -n scripts/github-action-entrypoint.sh
shellcheck service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh scripts/github-action-entrypoint.sh tests/*.sh
bash ./tests/versioning.sh
bash ./tests/run-all.sh
```

`tests/run-all.sh` is the authoritative inventory and fails if a test script is
not registered before running every scenario. `tests/schema.sh` needs Mike
Farah `yq` v4 and Python's `jsonschema` package. The suite isolates external
programs through PATH shims and temporary directories; follow that pattern when
adding a new check, notification channel, or command. GitHub Actions runs this
same suite on pushes and pull requests, and compiles every Bash source with the
official `bash:4.3.48` container to protect the documented compatibility floor.
The CI workflow also builds the public Docker Action and verifies valid and
invalid configuration exit codes.

## Preparing a repository release

Update `VERSION`, the stable archive URL and directory name in `README.md`, and
the dated changelog section before creating a tag. Then run the shared
preflight with the exact intended tag:

```bash
bash ./scripts/release-preflight.sh vX.Y.Z
```

It confirms the tag matches `VERSION`, the generated CLI reports that version,
the README points to the matching source archive, the changelog has a matching
heading, and the installer copies `VERSION`. The `Release metadata` GitHub
Actions workflow invokes the same script after a tag push, but passing it
locally catches a mismatch before an immutable release tag exists.

## Get help with useful evidence

When opening an issue, include the Watchdog version/commit, Linux and `yq`
versions, the exact command and exit code, redacted relevant log lines, and a
minimal configuration that contains no secret values. State whether the failure
occurs under a normal run, `--dry-run`, `validate`, `notify-test`, or `status`.
