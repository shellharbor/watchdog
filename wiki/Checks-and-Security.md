# Checks and Security Monitoring

Each service has either one `check` or HTTP `health.liveness` and
`health.readiness` checks. A check can retry before it is considered failed.
The available `check.type` values are `http`, `tcp`, `command`, `disk`,
`clamav`, and `threshold`.

## HTTP and HTTPS

HTTP checks use `curl`. They can send `GET` or `HEAD`, follow redirects, and
accept a selected list of status codes. Without `success_status`, every 2xx
response is healthy.

```yaml
services:
  - name: storefront
    check:
      type: http
      url: https://shop.example.com/health
      method: GET
      follow_redirects: true
      success_status: [200, 204]
      timeout: 10
      attempts: 3
      retry_delay: 2

  - name: edge-proxy
    check:
      type: http
      url: https://proxy.example.com/
      method: HEAD
      success_status: [301, 302]
```

Use a dedicated health endpoint where possible: public pages may return a
successful status while their database or queue is unavailable.

## TCP ports

TCP checks use Bash's `/dev/tcp` facility, so no separate `nc` dependency is
required. DNS names and IP addresses are both supported.

```yaml
services:
  - name: postgres
    check:
      type: tcp
      host: 127.0.0.1
      port: 5432
      timeout: 5
      attempts: 2

  - name: redis
    check: { type: tcp, host: redis.internal.example.com, port: 6379 }
```

A successful TCP connection proves reachability, not application-level
readiness. Pair it with an HTTP or command check where protocol-level health is
important.

## Command checks

A command check runs each listed command directly as argv. Every command must
succeed for the service to be healthy.

```yaml
services:
  - name: report-worker
    check:
      type: command
      attempts: 1
      commands:
        - command: [systemctl, is-active, --quiet, report-worker]
        - command: [/usr/local/bin/report-worker, healthcheck]
          timeout: 15
```

Avoid a shell string such as `"systemctl ... && curl ..."`. Split it into
separate argv entries as above. The direct form preserves argument boundaries
and prevents accidental shell expansion.

## Disk capacity

The `disk` check reads filesystem availability with `df`. It fails when **any
configured** free-space threshold is missed, so use both units when you want a
hard floor and a relative safety margin.

```yaml
services:
  - name: root-filesystem
    check:
      type: disk
      path: /
      min_free_gb: 10
      min_free_percent: 10
      attempts: 1

  - name: uploads-filesystem
    check:
      type: disk
      path: /var/www/uploads
      min_free_percent: 15
```

This check works naturally with ordinary global notification channels, so a
disk warning follows the same failure/recovery lifecycle as an HTTP service.
See [`examples/disk-space.yaml`](../examples/disk-space.yaml) for a complete
all-channel example.

## ClamAV scan

The `clamav` check invokes `clamscan`. It is optional: `validate` reports a
clear configuration error only when a service enables this type and the tool is
missing. A return indicating infected files makes the service unavailable;
operational errors are also surfaced.

```yaml
services:
  - name: uploaded-files-malware-scan
    check:
      type: clamav
      path: /var/www/uploads
      recursive: true
      timeout: 300
      attempts: 1
```

Run the watchdog account with read access only to the target tree; a scan does
not need write access. Choose an interval that will not overlap or overload
normal workload. For a separate scanner configuration, see
[`examples/security-monitoring.yaml`](../examples/security-monitoring.yaml).

## Event and connection thresholds

`threshold` turns a count from one of four sources into a check. It is useful
for detecting bursts rather than binary up/down failures. The service fails
when the comparison between the observed count and `threshold` is true.
Supported comparators are `>`, `>=`, `<`, `<=`, `==`, and `!=`.

### Failed SSH login attempts from journald

```yaml
services:
  - name: ssh-bruteforce
    check:
      type: threshold
      source:
        type: journald
        unit: sshd
        since: "5 minutes ago"
        pattern: "Failed password"
      threshold: 10
      comparator: ">"
      attempts: 1
```

`journald` needs `journalctl`; the monitor account must have permission to read
the relevant journal entries.

### Log-file pattern count

```yaml
services:
  - name: nginx-444-flood
    check:
      type: threshold
      source:
        type: logfile
        path: /var/log/nginx/access.log
        pattern: " 444 "
        tail_lines: 10000
      threshold: 1000
      comparator: ">"
```

`tail_lines` limits how much of a potentially large file is read. It is a
bounded tail, not a precise time window.

### TCP connection-state count

```yaml
services:
  - name: syn-recv-flood
    check:
      type: threshold
      source:
        type: netstat
        state: SYN-RECV
      threshold: 500
      comparator: ">"
```

The source uses `ss` or `netstat`, depending on what is available. Choose a
threshold based on observed baseline traffic before enabling alerts.

### Custom count command

```yaml
services:
  - name: queue-depth
    check:
      type: threshold
      source:
        type: command
        command: [/usr/local/bin/queue-depth]
        timeout: 10
      threshold: 10000
      comparator: ">="
      attempts: 1
```

The command may output a count or lines to be counted with a configured
`pattern`. It is trusted local configuration and should be fast, deterministic,
and bounded by a timeout.

## Choosing a check type

| Need | Recommended check |
| --- | --- |
| Endpoint can serve a health response | `http` |
| Only a socket must be reachable | `tcp` |
| A local program already knows health | `command` |
| A filesystem is close to full | `disk` |
| Scan a local file tree for malware | `clamav` |
| Alert on a count of events or connections | `threshold` |

For every new threshold, begin with a dry run and inspect the logged observed
count. Set an alert threshold above normal variability, then test notification
delivery with `notify-test` rather than manufacturing an incident.
