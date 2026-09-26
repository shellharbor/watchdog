# Configuration examples

These examples demonstrate common `service-watchdog` use cases. Copy the
closest example to a root-owned location and replace all domains, paths, ports,
service names, and commands before enabling scheduled runs.

| Example | Use case |
| --- | --- |
| [`http-docker-compose.yaml`](http-docker-compose.yaml) | Check an HTTP health endpoint and restart Docker Compose services |
| [`smart-http.yaml`](smart-http.yaml) | Assert JSON content safely with secret headers and a latency SLO |
| [`tcp-systemd.yaml`](tcp-systemd.yaml) | Check a TCP port and restart a systemd unit |
| [`command-check.yaml`](command-check.yaml) | Use a local command as the health check |
| [`disk-space.yaml`](disk-space.yaml) | Alert through email and webhooks when a filesystem runs low on free space |
| [`dns-ping.yaml`](dns-ping.yaml) | Verify authoritative DNS answers and ICMP packet loss/latency |
| [`tls-certificate.yaml`](tls-certificate.yaml) | Alert before a TLS leaf certificate expires, with optional SNI and port |
| [`security-monitoring.yaml`](security-monitoring.yaml) | ClamAV and threshold alerts for SSH, TCP socket states, and web logs |
| [`history/`](history) | Sample JSONL history snapshot and report input |
| [`multiple-services.yaml`](multiple-services.yaml) | Monitor HTTP, TCP, and systemd services in one run |
| [`hooks.yaml`](hooks.yaml) | Run notification hooks on failure and recovery transitions |
| [`smtp-email.yaml`](smtp-email.yaml) | Send built-in SMTP email on failure and recovery transitions |
| [`telegram-notifications.yaml`](telegram-notifications.yaml) | Send Telegram transition notifications with a bot token from the environment |
| [`market-data-server.yaml`](market-data-server.yaml) | Monitor PostgreSQL and a Go service with separate liveness/readiness, backoff, flapping, escalation, metrics, and an enforced action allowlist |
| [`auto-discovery/`](auto-discovery) | Generate a draft `services:` fragment from static Compose and systemd files |
| [`notify-test.yaml`](notify-test.yaml) | Test notification delivery explicitly after filling in SMTP settings and secrets |
| [`status-cli.yaml`](status-cli.yaml) | Read a service's persisted state with the terminal `status` command |
| [`status-page-uptime.yaml`](status-page-uptime.yaml) | Publish a static status page with 30 days of observed-availability bars |
| [`oncall-notifications.yaml`](oncall-notifications.yaml) | Open and resolve deduplicated PagerDuty and Opsgenie alerts |
| [`remote-http-remediation.yaml`](remote-http-remediation.yaml) | Invoke an allowlisted remote API safely as remediation |

Validate YAML and policy without running any checks or creating runtime state:

```bash
./service-watchdog.sh validate -c ./examples/market-data-server.yaml
```

Test a configuration without executing remediation commands or changing state:

```bash
sudo ./service-watchdog.sh \
  -c ./examples/http-docker-compose.yaml \
  -n
```

Check only one configured service:

```bash
sudo ./service-watchdog.sh \
  -c ./examples/multiple-services.yaml \
  -s public-api \
  -n
```

The paths in the examples are intentionally illustrative. Configuration
validation will fail until referenced working directories exist on the target
server.
