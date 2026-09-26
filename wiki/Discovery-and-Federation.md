# Discovery and Federation

Both features are opt-in and explicitly invoked or scheduled as normal
one-shot processes. Discovery creates a draft configuration fragment; it never
runs as part of ordinary monitoring. Federation has no built-in listener: an
agent sends a snapshot outward, while a hub reads delivered reports from a
directory.

## Offline discovery from Docker Compose and systemd

`watchdog-discover.sh` reads static Compose files and systemd unit files, then
generates a draft `services:` fragment. It does not execute Compose
healthchecks, service actions, or generated remediation commands.

```yaml
discovery:
  enabled: true
  output_dir: ""          # Empty writes a draft to stdout.
  output_prefix: "auto-"
  docker_compose:
    enabled: true
    sources:
      - /srv/project-a/compose.yml
      - /srv/project-b
    only_with_healthcheck: false
    skip_labels: ["watchdog.ignore=true"]
    http_ports: [80, 443, 8080, 3000, 8000, 8081, 8443]
    default_actions:
      cooldown: 300
      verify_after: 10
      commands:
        - command: [docker, compose, restart, "{{service_name}}"]
          working_directory: "{{compose_dir}}"
          timeout: 120
  systemd:
    enabled: true
    sources:
      - /etc/systemd/system/myapp-*.service
    only_service_types: [simple, notify, forking]
    skip_patterns: ["@", watchdog]
    detect_ports: true
    default_actions:
      cooldown: 300
      verify_after: 10
      commands:
        - command: [systemctl, restart, "{{unit_name}}"]
          timeout: 60
```

Preview before writing or merging anything:

```bash
bash ./watchdog-discover.sh --config ./config.yaml --dry-run
bash ./watchdog-discover.sh --config ./config.yaml --source docker --format stdout
bash ./watchdog-discover.sh --config ./config.yaml --source systemd --dry-run
```

Compose sources can be a Compose file or a directory containing a conventional
Compose filename. Discovery creates HTTP checks for configured published HTTP
ports and TCP checks for other published ports. Services with no usable port
are skipped. Systemd port detection is a best-effort `ExecStart` guess; a unit
without a guessed port receives a `systemctl is-active --quiet` command check.

Set `output_dir` to an absolute writable directory when you want a file:

```yaml
discovery:
  enabled: true
  output_dir: /etc/service-watchdog/config.d
  output_prefix: "auto-"
```

An ordinary generator run atomically writes a file such as
`auto-discovery.yaml` and will not replace an existing file unless `--force` is
explicitly supplied. Generated fragments are **not automatically loaded** by
Watchdog. Review and merge each service into the active configuration; then
validate target URLs, TLS, ports, action commands, and policy. See the complete
[offline discovery example](../examples/auto-discovery/README.md).

## Federation overview

```text
agent normal run → signed/authorized report delivery → hub incoming directory
                                                          ↓
                                                   hub normal run
                                                          ↓
                                             aggregate status + notifications
```

Use a separate configuration for the agent and hub. An enabled hub may use
`services: []`; agent and hub modes are not enabled together in the same
configuration.

## Agent configuration

The agent runs its local checks as usual, then sends a snapshot after the run.
HTTP transport posts to a remote endpoint; file transport writes an atomic
report for an external tool such as `rsync`, `scp`, Syncthing, or object storage
to deliver.

```yaml
federation:
  enabled: true
  node_id: web-01
  agent:
    enabled: true
    transport: http
    hub_url: https://watchdog-hub.internal/api/v1/report
    token_env: WATCHDOG_HUB_TOKEN
    timeout: 10
    report_path: /var/lib/service-watchdog/federation-report.json
    heartbeat: true
```

For a file-based hand-off:

```yaml
federation:
  enabled: true
  node_id: web-01
  agent:
    enabled: true
    transport: file
    report_path: /var/lib/service-watchdog/federation-report.json
    heartbeat: true
```

Keep `WATCHDOG_HUB_TOKEN` in the agent's protected runtime environment, never
in the configuration or copied report. Confirm the remote delivery endpoint
authenticates the token and accepts only expected data.

## Hub configuration

The hub reads reports an external delivery mechanism has already placed in its
incoming directory. It checks age, archives reports, and can notify when the
overall aggregate state changes or an expected agent goes offline.

```yaml
settings:
  log_file: /var/log/watchdog-hub/watchdog.log
  lock_file: /run/lock/watchdog-hub.lock
  state_directory: /var/lib/watchdog-hub

federation:
  enabled: true
  hub:
    enabled: true
    incoming_dir: /var/lib/watchdog-hub/incoming
    archive_dir: /var/lib/watchdog-hub/archive
    max_report_age: 300
    archive_retention_days: 7
    expected_nodes: [web-01, web-02]
    notify_on:
      overall_change: true
      agent_offline: true
      any_service_change: false
    templates:
      overall_failure:
        subject: "[FEDERATION] Infrastructure status: {{overall_status}}"
        body: |-
          Unhealthy services:
          {{unhealthy_services}}

          Offline nodes:
          {{offline_nodes}}
      overall_recovery:
        subject: "[FEDERATION] Infrastructure recovered"
        body: "All services are operational."
      agent_offline:
        subject: "[FEDERATION] Agent {{node_id}} is offline"
        body: "No report for {{age_seconds}} seconds."

services: []
```

Use restrictive permissions for `incoming_dir` and `archive_dir`; untrusted
local users must not be able to forge reports or delete evidence. Schedule the
hub on an interval below `max_report_age` so an offline agent is detected in a
timely manner.
