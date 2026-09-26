# Configuration Reference

Every configuration is YAML. Use the schema annotation as the **first line**
to get completion and validation in VS Code with the Red Hat YAML extension,
or map the same schema URL in a JetBrains IDE:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/shellharbor/watchdog/main/schema/watchdog.schema.json
```

The schema is useful while editing, but it does not replace the runtime
validator. Always run:

```bash
bash ./service-watchdog.sh validate -c ./config.yaml
```

## Required settings and defaults

```yaml
settings:
  log_file: /var/log/service-watchdog/service-watchdog.log
  lock_file: /run/lock/service-watchdog.lock
  state_directory: /var/lib/service-watchdog
  default_timeout: 10
  default_attempts: 2
  default_retry_delay: 2
  default_action_timeout: 120
  default_action_cooldown: 300
```

`log_file`, `lock_file`, and `state_directory` must be absolute paths. Values
in a service's `check` or `actions` section override the corresponding default.
Make the config root-owned and ensure the scheduling account can write only the
runtime paths it needs.

## Commands are argument arrays

Every configured command is a list: executable followed by individual
arguments. Do not use a string, pipe, redirection, `eval`, or `bash -c`.

```yaml
# Good: direct argv execution with a bounded command.
actions:
  commands:
    - command: [docker, compose, restart, api]
      working_directory: /srv/api
      timeout: 120

# Good: a command check with two ordered health commands.
check:
  type: command
  commands:
    - command: [systemctl, is-active, --quiet, api]
    - command: [curl, -fsS, http://127.0.0.1:8080/health]
      timeout: 10
```

Action/hook timeouts default to `settings.default_action_timeout`; check
timeouts default to `settings.default_timeout` unless a check type says
otherwise. Command checks and hooks are administrator-trusted configuration:
they can have side effects even in a `--dry-run` check phase, so use them with
care.

## Reusable templates

Templates are partial service definitions. A service names one template and
overrides its values. The default `deep` merge combines nested maps; a
service's own values win.

```yaml
templates:
  default_http:
    check:
      type: http
      timeout: 10
      attempts: 3
      retry_delay: 2
      success_status: [200, 204]
    actions:
      cooldown: 300
      verify_after: 10

services:
  - name: billing-api
    template: default_http
    check:
      url: https://billing.example.com/health
    actions:
      commands:
        - command: [systemctl, restart, billing-api]
```

Use `template_mode: shallow` only when a service must replace a complete
top-level section rather than extend it:

```yaml
templates:
  default_http:
    check: { type: http, timeout: 10, attempts: 3 }

services:
  - name: custom-probe
    template: default_http
    template_mode: shallow
    check:
      type: command
      commands: [{ command: [/usr/local/bin/custom-probe] }]
```

Templates cannot inherit from other templates. They may omit fields because
they are completed when a service references them.

## Conditional checks (`only_if`)

All configured conditions must pass before the service is checked. A failed
condition skips that service's check, actions, hooks, and notifications without
changing its stored state. Add `invert: true` to reverse a condition.

```yaml
services:
  - name: external-api
    check: { type: http, url: https://api.example.com/health }
    only_if:
      # Do not poll while the backup marker exists.
      - type: file_exists
        path: /var/run/backup-in-progress
        invert: true
      # Avoid making a loaded host worse.
      - type: load_average
        max_1min: 4.0
        max_5min: 3.0
      # Run outside Moscow business hours.
      - type: time_window
        days: "Mon,Tue,Wed,Thu,Fri"
        time: "09:00-18:00"
        timezone: Europe/Moscow
        invert: true
      # Keep a check from running when its filesystem is near exhaustion.
      - type: filesystem
        path: /
        min_free_gb: 5
      # Require an explicit local permit file.
      - type: command
        command: [test, -f, /var/run/allow-external-check]
        timeout: 5
        exit_code: [0]
```

The accepted condition types are `command`, `file_exists`, `time_window`,
`load_average`, and `filesystem`. Time ranges are same-day `HH:MM-HH:MM`; split
an overnight period into two windows.

## Service-level liveness and readiness

Use `health` instead of `check` to model a process that is alive but not yet
ready to accept traffic. Both endpoints are HTTP checks.

```yaml
services:
  - name: api
    health:
      liveness:
        type: http
        url: http://127.0.0.1:8080/live
        timeout: 5
      readiness:
        type: http
        url: http://127.0.0.1:8080/ready
        success_status: [200]
        timeout: 5
```

Do not combine a top-level `check` with `health`. The validator requires both
`liveness` and `readiness` when `health` is used.

## Global optional features

The following top-level blocks are disabled by default and are covered in their
dedicated pages:

| Block | Purpose | Guide |
| --- | --- | --- |
| `notifications`, `hooks`, `security.remediation_policy` | Alerting and controlled remediation | [Notifications and Remediation](Notifications-and-Remediation.md) |
| `parallel`, `history`, `metrics`, `status_page` | Runtime and observability outputs | [Operations, Status, and History](Operations-CLI-and-History.md) |
| `federation`, `discovery` | Multi-host aggregation and offline generation | [Discovery and Federation](Discovery-and-Federation.md) |
| `maintenance`, `flapping`, `escalation`, `circuit_breaker`, `depends_on` | Outage controls | [Reliability and Dependencies](Reliability-and-Dependencies.md) |

Refer to [`config.example.yaml`](../config.example.yaml) for a complete,
schema-annotated configuration with every block present but opt-in.
