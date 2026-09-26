# Deployment and Troubleshooting

Watchdog is designed for a scheduler. Treat its configuration, binaries,
environment files, state directory, and output directories as an operational
security boundary.

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
| No alert from a failed service | Confirm a transition actually occurred; repeated failure alerts are suppressed. Check enabled channels, environment variables, maintenance status, and the operational log. Use `notify-test`. |
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
bash -n service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh
shellcheck service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh
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

## Get help with useful evidence

When opening an issue, include the Watchdog version/commit, Linux and `yq`
versions, the exact command and exit code, redacted relevant log lines, and a
minimal configuration that contains no secret values. State whether the failure
occurs under a normal run, `--dry-run`, `validate`, `notify-test`, or `status`.
