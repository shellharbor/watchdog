# Reliability and Dependencies

This page describes the controls that keep a short-lived incident from turning
into alert noise or unsafe repeated remediation. All are opt-in. The check
phase can be parallel, but state changes, notifications, actions, hooks, and
output writes remain sequential.

## Retry, cooldown, and backoff

`attempts` and `retry_delay` apply before a check becomes unavailable. An
action cooldown limits how frequently remediation can run. Exponential backoff
adds a growing delay after failed remediation; both the cooldown and backoff
must have elapsed before another action runs.

```yaml
services:
  - name: api
    check:
      type: http
      url: https://api.example.com/health
      attempts: 3
      retry_delay: 5
    actions:
      cooldown: 300
      backoff:
        enabled: true
        initial_delay: 60
        multiplier: 2
        max_delay: 1800
      commands:
        - command: [systemctl, restart, api]
          timeout: 60
```

Use retries for transient connection loss, cooldown for expensive or disruptive
actions, and backoff for a problem that continues despite remediation.

## Maintenance windows

Maintenance windows are per service and use IANA time zones. Checks and state
updates continue, while remediation, email, webhooks, and state-change hooks
are suppressed. `notify-test` intentionally ignores the window because it is a
manual delivery test.

```yaml
services:
  - name: api
    check: { type: http, url: https://api.example.com/health }
    maintenance:
      timezone: Europe/Moscow
      windows:
        - name: nightly-backup
          days: "Sun,Wed"
          time: "02:00-04:00"
        - name: weekend-deploy
          days: "Sat,Sun"
          time: "00:00-06:00"
```

The start is included and the end is excluded. Windows cannot cross midnight:
write `22:00-23:59` and `00:00-02:00` as separate same-day windows. An outage
that begins during maintenance triggers one deferred failure notification when
the window ends if it is still unavailable.

## Flapping guard

The flapping guard watches state transitions rather than every failed probe. It
blocks automatic remediation after a service changes state repeatedly in a
short interval, then waits for a minimum hold and stable healthy period.

```yaml
services:
  - name: api
    check: { type: http, url: https://api.example.com/health }
    flapping:
      enabled: true
      window_seconds: 300
      threshold: 3
      hold_seconds: 600
      recovery_seconds: 120
      notify: true
```

The guard does not turn off health checks. It protects a bouncing system from
restarts that may make the incident worse.

## Escalation and manual intervention

Escalation responds to an outage that persists across multiple runs. It can
notify, execute separate escalation actions, run escalation hooks, and set a
manual-intervention block at a level threshold.

```yaml
services:
  - name: worker
    check:
      type: command
      commands: [{ command: [systemctl, is-active, --quiet, worker] }]
    escalation:
      enabled: true
      after_consecutive_unavailable: 3
      cooldown: 3600
      notify: true
      levels:
        - after_duration_seconds: 900
          notify: true
        - after_failed_remediations: 5
          notify: true
          manual_intervention: true
      actions:
        commands:
          - command: [/usr/local/bin/page-oncall]
            timeout: 30
      hooks:
        on_escalation:
          - command: [/usr/local/bin/create-major-incident]
            timeout: 30
```

The primary threshold and any configured duration/failed-remediation thresholds
use OR semantics. A level fires once per incident. Maintenance suppresses
escalation; flapping, an open circuit breaker, or a manual block suppresses
escalation action commands and hooks. The counter resets on recovery.

## Circuit breaker

The circuit breaker stops automatic remediation after a configured number of
consecutive failures and reopens the possibility after its cool-down period.

```yaml
services:
  - name: api
    check: { type: http, url: https://api.example.com/health }
    circuit_breaker:
      enabled: true
      failure_threshold: 3
      open_duration: 1800
      half_open_verify_after: 30
      notify: true
      hooks:
        on_open:
          - command: [/usr/local/bin/notify-sre]
            timeout: 30
        on_close:
          - command: [/usr/local/bin/notify-sre]
            timeout: 30
```

Use it for remediation that could harm a dependency, consume rate limits, or
otherwise should not continue indefinitely. The read-only `status` command
shows the circuit state and next blocked action.

## Dependency chains

Dependencies describe the order in which services should be checked. Required
failed dependencies prevent downstream checks, alerts, and remediation; the
downstream state is recorded as `dependency_failed`. Soft dependencies log a
warning but do not block a check.

```yaml
services:
  - name: db
    check: { type: tcp, host: 127.0.0.1, port: 5432 }

  - name: api
    check: { type: http, url: http://127.0.0.1:8080/health }
    depends_on:
      - name: db
        required: true

  - name: frontend
    check: { type: http, url: http://127.0.0.1:3000/ }
    depends_on:
      - name: api
        required: true
      - name: analytics
        required: false
```

```text
db ──required──► api ──required──► frontend
                     analytics ──soft──────► frontend
```

Missing names and circular graphs fail validation. If the dependent service was
already independently unavailable, Watchdog retains that state rather than
hiding its existing incident.

## Parallel checks

Enable parallelism when many independent health checks make a one-shot run too
slow. Only check execution is concurrent. Dependency levels still run in order
so required failures are known before consumers are considered.

```yaml
parallel:
  enabled: true
  max_jobs: 10  # 0 means no limit
  timeout: 60   # fallback; a service check.timeout wins
  temp_dir: ""  # empty creates a private /tmp/watchdog directory

services:
  - name: public-api
    check: { type: http, url: https://api.example.com/health }
  - name: legacy-worker
    parallel: false
    check:
      type: command
      commands: [{ command: [/usr/local/bin/check-legacy-worker] }]
```

Disable parallelism for a check that reads a non-concurrent resource or has
side effects. Keep the scheduler interval longer than the slowest expected
run; the global lock rejects accidental overlap.
