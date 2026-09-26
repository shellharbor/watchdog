# ShellHarbor Watchdog Wiki

ShellHarbor Watchdog is a one-shot Bash monitor for Linux. It checks services,
records their state, delivers transition-based alerts, and can run explicitly
configured remediation commands. Run it from a systemd timer, cron, or another
scheduler; it does not start a daemon or listen on a port.

This Wiki is a task-oriented companion to the complete
[`README.md`](../README.md), the validated
[`config.example.yaml`](../config.example.yaml), and the configuration
[`JSON Schema`](../schema/watchdog.schema.json). Copy examples into a private,
root-owned configuration and adapt every host name, path, command, recipient,
and threshold before scheduling a production run.

## Project community

- [Contributing](../CONTRIBUTING.md) explains the focused, test-first workflow.
- [Security](../SECURITY.md) provides a private vulnerability-reporting path and
  secure deployment checklist.
- [Support](../SUPPORT.md) helps distinguish configuration questions, bugs, and
  security reports without exposing production secrets.
- [Code of Conduct](../CODE_OF_CONDUCT.md) defines a respectful collaboration
  standard for issues, pull requests, and other project spaces.
- [Releasing](../RELEASING.md) documents the version/tag verification process.

## Start here

- [Quick Start](Quick-Start.md) — install, validate, run, and schedule a first check.
- [Configuration Reference](Configuration-Reference.md) — settings, templates, conditions, and safe command syntax.
- [Checks and Security Monitoring](Checks-and-Security.md) — HTTP, TCP, commands, disk capacity, ClamAV, and event thresholds.
- [Notifications and Remediation](Notifications-and-Remediation.md) — email, Telegram, Discord, Slack, ntfy, hooks, and recovery actions.
- [Reliability and Dependencies](Reliability-and-Dependencies.md) — retries, cooldowns, backoff, flapping, maintenance, escalation, circuit breakers, dependencies, and parallel checks.
- [Operations, Status, and History](Operations-CLI-and-History.md) — `status`, `notify-test`, history, reports, trends, metrics, and status pages.
- [Discovery and Federation](Discovery-and-Federation.md) — offline Docker Compose/systemd discovery and agent/hub monitoring.
- [Deployment and Troubleshooting](Deployment-and-Troubleshooting.md) — systemd, cron, permission boundaries, tests, and incident diagnosis.

## Mental model

```text
scheduler → one watchdog run → checks → sequential state processing
                                      ├→ alert on a state transition
                                      ├→ optional remediation
                                      ├→ optional hooks / escalation
                                      └→ optional history, metrics, status page
```

The monitor normally sends one failure notification when a service becomes
unavailable and one recovery notification when it becomes healthy again. A
continuing failure does not create duplicate alerts. Maintenance windows change
that rule only by suppressing side effects while checks and state tracking
continue.

## A practical first configuration

This compact configuration monitors an API, a database port, a worker process,
and the root filesystem. It demonstrates four check types without enabling
remediation. Notification channels are global: a failure from any configured
service reaches every enabled channel.

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/shellharbor/watchdog/main/schema/watchdog.schema.json
settings:
  log_file: /var/log/service-watchdog/service-watchdog.log
  lock_file: /run/lock/service-watchdog.lock
  state_directory: /var/lib/service-watchdog
  default_timeout: 10
  default_attempts: 2

notifications:
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WATCHDOG_TG_BOT_TOKEN
      chat_id: "-1001234567890"

services:
  - name: public-api
    check:
      type: http
      url: https://api.example.com/health
      success_status: [200, 204]

  - name: postgres
    check: { type: tcp, host: 127.0.0.1, port: 5432 }

  - name: worker
    check:
      type: command
      commands:
        - command: [systemctl, is-active, --quiet, example-worker]

  - name: root-disk
    check:
      type: disk
      path: /
      min_free_gb: 10
      min_free_percent: 10
```

Export the secret named by `bot_token_env`, then validate and exercise this
configuration without changing state or sending alerts:

```bash
export WATCHDOG_TG_BOT_TOKEN='replace-with-a-real-token'
bash ./service-watchdog.sh validate -c ./config.yaml
sudo bash ./service-watchdog.sh -c ./config.yaml --dry-run
```

Use `notify-test` to prove delivery instead of breaking a healthy service:

```bash
bash ./service-watchdog.sh notify-test -c ./config.yaml -s public-api
```

## Safety principles

- Keep credentials out of YAML. Reference them with `*_env` fields and load
  their values through systemd or the scheduler environment.
- Commands are YAML argv arrays such as `[systemctl, restart, api]`; they are
  not shell strings. Configuration never uses `eval` or a configured `bash -c`.
- Start with `validate`, then `--dry-run`, before a normal run. A dry run may
  perform checks but never changes state, sends alerts, runs actions, hooks, or
  writes history, metrics, or status pages.
- Treat remediation commands and hooks as administrator-trusted code. When
  possible, enable the exact-command allowlist described in
  [Notifications and Remediation](Notifications-and-Remediation.md).
- `status`, `--report`, and `--trend` are read-only. They do not execute
  checks or acquire the monitor lock.

## Ready-made examples

The [`examples/`](../examples) directory contains complete starting points for
[Docker Compose](../examples/http-docker-compose.yaml),
[systemd TCP checks](../examples/tcp-systemd.yaml),
[disk thresholds](../examples/disk-space.yaml),
[security monitoring](../examples/security-monitoring.yaml),
[notification delivery tests](../examples/notify-test.yaml), and more.
Validate a copied example before relying on it: illustrative paths and service
names intentionally require local adjustment.
