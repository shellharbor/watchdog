# Notifications and Remediation

Watchdog sends failure and recovery notifications on state transitions. One
failure notification is sent when a healthy/unknown service becomes
unavailable; repeated unavailable checks do not flood recipients. A recovery
notification follows when that service becomes healthy again.

All notification channels are global. Enable one or more channels under
`notifications`; each configured service uses them. Per-service message
content is controlled by template variables such as `{{service}}` and
`{{detail}}`.

## Email via SMTP

Use `password_env` for an SMTP password. `password` remains an inline
alternative, but never set both fields and do not commit secrets to YAML.
When SMTP authentication is enabled, Watchdog supplies credentials from an
ephemeral mode-`0600` curl configuration file and removes it immediately after
delivery; the password is never placed in curl's process command line.

```yaml
notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.com:465
      from: watchdog@example.com
      username: watchdog@example.com
      password_env: WATCHDOG_SMTP_PASSWORD
      tls_required: true
      insecure_skip_verify: false
      timeout: 30
    recipients:
      - ops@example.com
      - on-call@example.com
    failure:
      subject: "[watchdog] {{service}} is unavailable"
      body: |-
        Service: {{service}}
        Time: {{timestamp}}
        Detail: {{detail}}
        HTTP status: {{http_status}}
        Action: {{action_status}}
    recovery:
      subject: "[watchdog] {{service}} recovered"
      body: "Recovered at {{timestamp}}."
```

For STARTTLS, use `smtp://smtp.example.com:587` rather than `smtps://...:465`.
Keep certificate verification enabled except for a deliberately trusted
self-signed server.

For the included systemd service, place the actual secret in its protected
environment file:

```bash
sudo install -m 0600 /dev/null /etc/service-watchdog/environment
sudoedit /etc/service-watchdog/environment
```

```text
WATCHDOG_SMTP_PASSWORD=replace-with-the-real-password
```

## Webhooks: Telegram, Discord, Slack, and ntfy

Webhook credentials are also environment references. Dynamic values are safely
rendered into the provider payload; never replace an `*_env` field with a
literal production credential.

```yaml
notifications:
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WATCHDOG_TG_BOT_TOKEN
      chat_id: "-1001234567890"
      # thread_id: "42"  # Optional forum topic.
      template:
        failure: "🚨 <b>{{service}}</b> DOWN\n\n{{detail}}"
        recovery: "✅ <b>{{service}}</b> recovered"

    discord:
      enabled: true
      webhook_url_env: WATCHDOG_DISCORD_WEBHOOK_URL
      template:
        failure: '{"content":"🚨 **{{service}}** is unavailable: {{detail}}"}'
        recovery: '{"content":"✅ **{{service}}** recovered"}'

    slack:
      enabled: true
      webhook_url_env: WATCHDOG_SLACK_WEBHOOK_URL
      template:
        failure: '{"text":"🚨 {{service}} DOWN: {{detail}}"}'
        recovery: '{"text":"✅ {{service}} recovered"}'

    ntfy:
      enabled: true
      url: https://ntfy.sh/watchdog-alerts
      token_env: WATCHDOG_NTFY_TOKEN  # Optional for a public topic.
      priority: urgent
      template:
        failure: "🚨 {{service}} unavailable: {{detail}}"
        recovery: "✅ {{service}} recovered"
```

Telegram messages use HTML parse mode. Discord and Slack templates must be
valid JSON objects. ntfy sends the rendered template as its request body. A
missing secret fails only that channel and records the **variable name**, never
the secret value, in the operational log.

## Template variables

The ordinary failure and recovery templates receive:

- `{{service}}`, `{{event}}`, and `{{timestamp}}`
- `{{check_type}}`, `{{detail}}`, `{{http_status}}`, and `{{check_exit}}`
- `{{action_status}}`
- incident values when available: `{{incident_id}}`,
  `{{incident_duration}}`, and related incident context

Escalation messages use the same notification transports. Keep subjects
single-line; bodies may use YAML multiline blocks.

## Test delivery safely

`notify-test` explicitly delivers a marked test message. It does not run a
check, change state/history/metrics/status pages, acquire the global lock, or
run remediation or hooks. It also ignores a maintenance window but warns when
the selected service is currently in one.

```bash
# Test all enabled channels with a synthetic failure for service api.
bash ./service-watchdog.sh notify-test -c ./config.yaml -s api

# Test only Slack with recovery templates.
bash ./service-watchdog.sh notify-test -c ./config.yaml \
  --channel slack --event recovery

# Use watchdog-test as the synthetic service name and escalation templates.
bash ./service-watchdog.sh notify-test -c ./config.yaml \
  --channel all --event escalation
```

Outgoing subjects and channel text include `[TEST]`. The terminal output is a
`CHANNEL | RESULT | DETAIL` table. Exit `0` means every selected, enabled
channel succeeded; `1` means at least one failed; `2` indicates invalid config
or that no selected channel is enabled.

## Remediation commands

Actions run only after a service is unavailable and after retry attempts are
exhausted. They are ordered and direct argv invocations. `verify_after` waits
before a post-action readiness verification.

```yaml
services:
  - name: api
    check: { type: http, url: http://127.0.0.1:8080/health }
    actions:
      cooldown: 300
      verify_after: 10
      commands:
        - command: [systemctl, restart, api]
          timeout: 60
        - command: [systemctl, is-active, --quiet, api]
          timeout: 10
```

The action cooldown limits repeated remediations. For growing delays after
failed actions, add `actions.backoff` as described in
[Reliability and Dependencies](Reliability-and-Dependencies.md).

## Restrict remediation with an allowlist

Legacy mode preserves existing configurations. In `enforce` mode, list every
exact executable and argument vector used by normal and escalation actions.

```yaml
security:
  remediation_policy:
    mode: enforce
    allowed_commands:
      - command: [/usr/bin/systemctl, restart, api]
      - command: [/usr/bin/systemctl, restart, worker]
```

Validation and execution reject relative/symlink executable paths, shebang
scripts, wrapper shells, and argument vectors absent from the allowlist. This
is a guardrail, not a sandbox: trusted binaries and privileged service
accounts still need careful filesystem permissions. The policy covers
`actions.commands` and `escalation.actions.commands`, not health checks,
conditions, or hooks.

## Hooks

Hooks run on failure/recovery transitions and can integrate with a local pager,
ticket tool, or audit system. They receive `WATCHDOG_SERVICE`,
`WATCHDOG_EVENT`, `WATCHDOG_DETAIL`, `WATCHDOG_CHECK_TYPE`,
`WATCHDOG_HTTP_STATUS`, and `WATCHDOG_CHECK_EXIT` as environment variables.

```yaml
hooks:
  on_failure:
    - command: [/usr/local/bin/open-incident]
      timeout: 30
  on_recovery:
    - command: [/usr/local/bin/resolve-incident]
      timeout: 30
```

Hooks are suppressed in maintenance windows and in `--dry-run`. Handle
idempotency in the integration: Watchdog's transition behavior prevents
ordinary duplicate calls, but external tools may be retried or invoked by
other automation.
