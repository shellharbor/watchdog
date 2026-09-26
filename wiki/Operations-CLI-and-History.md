# Operations, Status, and History

Watchdog has a normal monitoring run plus read-only operational commands.
Read-only commands validate their input and inspect persisted data, but do not
run checks or acquire the monitor lock.

## Run modes at a glance

| Command | Performs checks | Changes monitoring state | Sends alerts/actions |
| --- | --- | --- | --- |
| `validate` | No | No | No |
| normal run | Yes | Yes | On transitions / according to policy |
| `--dry-run` | Yes | No | No |
| `status` | No | No | No |
| `--report` / `--trend` | No | No | No |
| `notify-test` | No | No | Test notifications only |

## Inspect the latest state

`status` reads state files from `settings.state_directory`. Configured services
with no saved state are shown as `unknown`; this makes a first-run gap visible
instead of silently treating it as healthy.

```bash
# All configured services in a readable table.
bash ./service-watchdog.sh status -c ./config.yaml

# One service only.
bash ./service-watchdog.sh status -c ./config.yaml -s api

# Include state files whose service no longer exists in YAML.
bash ./service-watchdog.sh status -c ./config.yaml --all
```

The table contains:

```text
SERVICE | STATE | PHASE | SINCE | LAST CHECK | NEXT ACTION | CIRCUIT | FLAPPING | MAINT | ESC
```

`STATE` is one of `healthy`, `unavailable`, `degraded`, `recovering`,
`dependency_failed`, or `unknown`. `NEXT ACTION` explains cooldown/backoff time
remaining or an automatic-action block such as `blocked: circuit-open`,
`blocked: flapping`, or `blocked: manual`. Colors appear only on a terminal and
are disabled by `NO_COLOR`.

The status exit code is `0` only when every displayed service is healthy;
`1` means at least one is not healthy (including unknown); `2` is an error.

## Consume status as JSON

Use `--json` for scripts and dashboards. It writes one JSON array with stable
machine-oriented values: durations are seconds and timestamps are ISO-8601
UTC.

```bash
bash ./service-watchdog.sh status -c ./config.yaml --json
```

Example record:

```json
{
  "service": "api",
  "state": "healthy",
  "phase": "healthy",
  "since_seconds": 60,
  "last_check": "2026-01-01T12:00:00Z",
  "next_action": "n/a",
  "next_action_seconds": null,
  "circuit": "closed",
  "flapping": false,
  "maintenance": null,
  "escalations": 0,
  "orphaned": false
}
```

For a state file not represented in the current configuration, `--all` sets
`orphaned` to `true`. Treat the schema as stable input and do not parse the
human-readable table.

## Record history

The incident ledger is always bounded and records incidents. Optional history
is a separate per-check time series. It is disabled by default and records a
snapshot only after a completed normal check; dry runs and services skipped by
conditions, maintenance handling, or dependency failure do not add snapshots.

### JSON Lines storage

JSONL needs no new dependency. Daily rotation produces one file per date and
can discard old files.

```yaml
history:
  enabled: true
  storage: jsonl
  path: /var/lib/service-watchdog/history
  rotation:
    mode: daily
    max_age_days: 30
    max_records: 0
  reports:
    trend_dots: 60
```

In `daily` mode, Watchdog writes `history_YYYY-MM-DD.jsonl`. Use `single` mode
to retain one `history.jsonl`; set `rotation.max_records` to cap it. A limit of
`0` disables that particular retention limit.

### SQLite storage

For SQL analysis, use the optional SQLite backend. `validate` requires the
`sqlite3` command only when this storage is enabled.

```yaml
history:
  enabled: true
  storage: sqlite
  path: /var/lib/service-watchdog/history.db
  rotation:
    mode: single
    max_records: 100000
```

Ensure `history.fields`, when customized, retains `timestamp`, `service`, and
`state`; reports require those fields. The default stores all available fields.

## Reports and ASCII trends

Reports and trends require `history.enabled: true`, validate the configuration,
and then only read saved snapshots.

```bash
# Since local midnight, the last 7 days, or the last calendar month.
bash ./service-watchdog.sh --report daily -c ./config.yaml
bash ./service-watchdog.sh --report weekly -c ./config.yaml
bash ./service-watchdog.sh --report monthly -c ./config.yaml

# Recent sampled state sequence for one service.
bash ./service-watchdog.sh --trend api -c ./config.yaml
```

These reports estimate availability from samples, not a continuous-time SLA.
An outage that begins and ends between scheduled runs cannot be measured, and
the reported downtime/MTTR is based on the interval between recorded
unavailable and recovery samples.

## Prometheus textfile collector

Watchdog can atomically replace a `.prom` file for node_exporter's textfile
collector. It does not open an HTTP port or run another daemon.

```yaml
metrics:
  enabled: true
  textfile_directory: /var/lib/node_exporter/textfile_collector
  filename: watchdog.prom
  prefix: watchdog
  static_labels:
    instance: prod-web-01
    datacenter: msk-1
```

Configure node_exporter with:

```text
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

Example PromQL alert condition:

```promql
watchdog_service_state{service="api"} == 1
```

The exported states use `0` healthy, `1` unavailable, `2` unknown,
`3` dependency failed, `4` degraded, and `5` recovering. Metrics include check
and action counters, incident duration, escalation count, and action blockers;
they never include incident IDs, command output, or secrets as labels.

## Static status page

Enable the static page when a web server can publish an output directory. It
creates HTML and JSON files after normal runs; Watchdog itself does not serve
them.

```yaml
status_page:
  enabled: true
  output_directory: /var/www/status
  html_filename: index.html
  json_filename: status.json
  title: Production Status
  description: Availability of public services
  auto_refresh: 60
  footer: Powered by Watchdog
  uptime:
    enabled: true
    days: 30
    buckets: 30
  theme:
    primary: "2563eb"
    danger: "dc2626"
    warning: "f59e0b"
    bg: "f8fafc"
    card: "ffffff"
    text: "1e293b"
    muted: "64748b"
```

The monitor account needs safe write permission to the output directory. Do
not place authentication tokens, raw check output, or configuration files in a
published location.

`status_page.uptime` is disabled by default and requires `history.enabled:
true`. It adds dependency-free CSS bars for equal intervals across the trailing
`days` window. The last recorded observation in an interval determines its
color: green for healthy, orange for degraded/recovering, red for
unavailable/dependency failure, and grey when no observation exists. These are
observed samples rather than a continuous-time SLA. Keep history retention at
least as long as `uptime.days` to retain the intended window.
