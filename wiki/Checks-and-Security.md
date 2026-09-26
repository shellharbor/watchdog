# Checks and Security Monitoring

Each service has either one `check` or HTTP `health.liveness` and
`health.readiness` checks. A check can retry before it is considered failed.
The available `check.type` values are `http`, `tcp`, `dns`, `ping`, `command`,
`disk`, `tls_cert`, `clamav`, and `threshold`.

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

### Assertions, secret headers, and latency SLOs

Add literal non-secret headers with `value`. For tokens and credentials, use
`value_env`; its environment-variable value is passed directly to `curl` and is
never written to logs, state, metrics, history, or the status page.

```yaml
services:
  - name: orders-api
    check:
      type: http
      url: https://orders.example.com/health
      headers:
        - name: Accept
          value: application/json
        - name: Authorization
          value_env: WATCHDOG_ORDERS_API_TOKEN
      expect:
        content_type: application/json
        body_regex: '"ready"[[:space:]]*:[[:space:]]*true'
        max_total_ms: 500
```

`content_type` matches the media type and ignores parameters such as
`charset=utf-8`. `body_regex` is an extended regular expression; Watchdog
captures at most 64 KiB in a private temporary file, checks it, and deletes it
without placing the body in diagnostics. A content-type or body mismatch is an
ordinary failed check. A successful response slower than `max_total_ms` becomes
`degraded`: it sends a transition alert and exports HTTP latency metrics, but
never runs remediation or changes circuit-breaker, backoff, flapping, or
unavailable-counter state. See
[`examples/smart-http.yaml`](../examples/smart-http.yaml) for a complete file.

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

## DNS records

The optional `dns` check invokes `dig +short`. It supports `A`, `AAAA`,
`CNAME`, `MX`, `NS`, and `TXT` records. `expected_answers` compares exact
non-empty output lines; this detects a wrong A record or missing mail exchanger
rather than merely testing that a resolver responds.

```yaml
services:
  - name: public-api-dns
    check:
      type: dns
      name: api.example.com
      record_type: A
      resolver: 1.1.1.1
      min_answers: 1
      expected_answers: [203.0.113.42]
```

Install `dig` only on hosts using this type. `validate` returns exit code `2`
when it is missing. For CNAME, MX, NS, and TXT, copy the expected value exactly
as `dig +short` prints it.

## ICMP reachability

The optional Linux `ping` check tests basic host reachability. Its default
`max_packet_loss_percent: 0` treats even partial loss as a failure; set
`max_avg_rtt_ms` when latency is also operationally meaningful.

```yaml
services:
  - name: upstream-router
    check:
      type: ping
      host: 192.0.2.1
      count: 3
      max_packet_loss_percent: 0
      max_avg_rtt_ms: 50
```

Some healthy firewalls intentionally drop ICMP. Use TCP or HTTP checks when the
service contract, rather than host reachability, is what matters.

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

## TLS certificate expiry

The `tls_cert` check retrieves the leaf certificate presented by a TLS endpoint
and fails when it has fewer than `min_days_remaining` whole days remaining.
`host` and `min_days_remaining` are required. `port` defaults to `443`, while
`server_name` defaults to `host` and is supplied as TLS SNI.

```yaml
services:
  - name: public-api-tls
    check:
      type: tls_cert
      host: api.example.com
      port: 443
      server_name: api.example.com
      min_days_remaining: 21
      timeout: 10
      attempts: 1
```

Install `openssl` only on hosts that enable this check; `validate` reports an
actionable error when it is missing. Watchdog records the expiry timestamp and
`days_remaining` in ordinary check detail, so regular failure/recovery alerts,
hooks, history, and logs include the useful operator context without persisting
the certificate itself. An already expired certificate always fails, including
with `min_days_remaining: 0`.

This is an expiry monitor, not a chain or hostname-trust validator. Add an HTTPS
`http` check when you also need normal curl CA and hostname verification. See
[`examples/tls-certificate.yaml`](../examples/tls-certificate.yaml) for the
complete file.

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
| A DNS record must have a known answer | `dns` |
| A host must reply to ICMP | `ping` |
| A local program already knows health | `command` |
| A filesystem is close to full | `disk` |
| A TLS certificate is nearing expiry | `tls_cert` |
| Scan a local file tree for malware | `clamav` |
| Alert on a count of events or connections | `threshold` |

For every new threshold, begin with a dry run and inspect the logged observed
count. Set an alert threshold above normal variability, then test notification
delivery with `notify-test` rather than manufacturing an incident.
