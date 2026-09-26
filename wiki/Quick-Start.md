# Quick Start

This guide brings up one HTTP check safely. The same flow applies to TCP,
command, disk, and security checks.

## 1. Install prerequisites

Watchdog requires Linux, Bash 4.3+, Mike Farah `yq` v4, `curl`, `flock`, and
GNU coreutils (including `timeout`). On Debian or Ubuntu:

```bash
sudo apt-get update
sudo apt-get install bash curl util-linux coreutils unzip
yq --version  # Must say Mike Farah yq version v4.x.x
```

The Python package called `yq` is not compatible. Install Mike Farah's
release through your distribution or its official instructions.

Clone the project, or download a release from GitHub:

```bash
git clone https://github.com/shellharbor/watchdog.git
cd watchdog
```

For a standard installation, use the included installer. It checks
dependencies, installs the script and example configuration, creates runtime
directories, installs the systemd units, and preserves an existing
configuration:

```bash
sudo ./install.sh
```

For a manual installation, place the script and private config in a stable
location:

```bash
sudo install -d -m 0755 /opt/service-watchdog
sudo install -m 0755 service-watchdog.sh /opt/service-watchdog/
sudo install -m 0640 config.example.yaml /opt/service-watchdog/config.yaml
sudoedit /opt/service-watchdog/config.yaml
```

## 2. Define a minimal service

Save this as `/etc/service-watchdog/config.yaml` (or a project-local file while
testing). The three `settings` paths are required.

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/shellharbor/watchdog/main/schema/watchdog.schema.json
settings:
  log_file: /var/log/service-watchdog/service-watchdog.log
  lock_file: /run/lock/service-watchdog.lock
  state_directory: /var/lib/service-watchdog

services:
  - name: api
    check:
      type: http
      url: https://api.example.com/health
      method: GET
      success_status: [200]
      timeout: 10
      attempts: 2
      retry_delay: 2
```

An HTTP check accepts every 2xx response by default. Set `success_status` when
your endpoint intentionally returns another status such as `204`.

## 3. Validate before running

`validate` expands templates and checks configuration rules, installed
dependencies needed by enabled features, time zones, dependency graphs,
directories, and action policy. It does not run checks or create runtime files.

```bash
sudo /opt/service-watchdog/service-watchdog.sh validate \
  -c /etc/service-watchdog/config.yaml
```

Use a dry run next. It performs the health check and writes diagnostics, but
does not alter state, send messages, run remediation, execute hooks, or write
metrics/history/status pages.

```bash
sudo /opt/service-watchdog/service-watchdog.sh \
  -c /etc/service-watchdog/config.yaml --dry-run
```

Finally, start one normal run:

```bash
sudo /opt/service-watchdog/service-watchdog.sh \
  -c /etc/service-watchdog/config.yaml
```

Exit code `0` means selected services were healthy and no remediation ran;
`1` represents an unavailable service or an attempted action; `2` means a
configuration or runtime problem. A non-zero `1` is a monitoring result, not
necessarily an execution failure of the scheduler.

## 4. Add an alert channel

This example uses Telegram. Only the environment variable name goes into YAML;
keep its token outside the config.

```yaml
notifications:
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WATCHDOG_TG_BOT_TOKEN
      chat_id: "-1001234567890"
      template:
        failure: "🚨 <b>{{service}}</b> DOWN: {{detail}}"
        recovery: "✅ <b>{{service}}</b> recovered at {{timestamp}}"
```

For an interactive test only:

```bash
export WATCHDOG_TG_BOT_TOKEN='replace-with-real-token'
bash ./service-watchdog.sh notify-test -c ./config.yaml -s api --channel telegram
```

`notify-test` never runs checks, actions, or hooks; it adds `[TEST]` to the
outgoing message and does not modify monitor state. See
[Notifications and Remediation](Notifications-and-Remediation.md) for systemd
environment files, email, and other webhooks.

## 5. Schedule the one-shot monitor

The installer provides a one-minute systemd timer:

```bash
sudo systemctl enable --now service-watchdog.timer
systemctl list-timers service-watchdog.timer
sudo journalctl -u service-watchdog.service -n 50 --no-pager
```

When using cron instead, schedule the script under an account with the exact
permissions required for its checks and remediation:

```cron
* * * * * /opt/service-watchdog/service-watchdog.sh -c /etc/service-watchdog/config.yaml >> /var/log/service-watchdog/cron.log 2>&1
```

The global non-blocking `flock` lock prevents overlapping runs. A slow run does
not pile up a queue of remediation attempts.

## Next steps

- Add [safe remediation and a cooldown](Notifications-and-Remediation.md).
- Monitor [disk space, security events, or application dependencies](Checks-and-Security.md).
- Configure [quiet maintenance windows and outage controls](Reliability-and-Dependencies.md).
- Learn read-only [status, report, and trend commands](Operations-CLI-and-History.md).
