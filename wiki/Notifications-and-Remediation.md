# Notifications and Remediation

Watchdog sends failure and recovery notifications on state transitions. One
failure notification is sent when a healthy/unknown service becomes
unavailable; repeated unavailable checks do not flood recipients. A recovery
notification follows when that service becomes healthy again.

Notification channels are configured globally under `notifications`. By
default, every configured service uses every enabled channel. A service can
opt into a smaller delivery set with `notify.channels`; message context can
include `{{severity}}` and `{{runbook_url}}` as well as `{{service}}` and
`{{detail}}`.

## Per-service routing, severity, and runbooks

```yaml
services:
  - name: payments-api
    check: {type: http, url: https://payments.example.com/health}
    notify:
      channels: [telegram, pagerduty, opsgenie]
      severity: critical
      runbook_url: https://runbooks.example.com/payments-api
```

`channels` accepts `email`, `telegram`, `discord`, `slack`, `ntfy`,
`pagerduty`, and `opsgenie`. It only filters channels already enabled at the
top level; it never enables a provider by itself. Omit `channels` to retain
the original all-enabled-channel behavior.

Severity values are `info`, `warning`, `error`, and `critical`. They render as
`{{severity}}`; PagerDuty receives the same value, while Opsgenie maps them to
`P5`, `P3`, `P2`, and `P1`, respectively. A missing severity retains the
legacy defaults: `error` for failure and `critical` for escalation. A
recovery renders as `info`. A non-secret HTTP(S) `runbook_url` renders as `{{runbook_url}}` and is included
in PagerDuty and Opsgenie trigger payloads. Do not put credentials or secret
query parameters in the URL.

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

## Webhooks: Telegram, Discord, Slack, ntfy, PagerDuty, and Opsgenie

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

### PagerDuty and Opsgenie

PagerDuty and Opsgenie are on-call providers, not generic JSON webhooks. A
failure creates or updates an alert, escalation raises its urgency, and recovery
resolves that exact alert. Watchdog uses its persisted incident ID as PagerDuty's
deduplication key and Opsgenie's alias, preventing duplicate incidents during a
continuing outage.

```yaml
notifications:
  webhooks:
    pagerduty:
      enabled: true
      routing_key_env: WATCHDOG_PAGERDUTY_ROUTING_KEY
    opsgenie:
      enabled: true
      api_key_env: WATCHDOG_OPSGENIE_API_KEY
      region: eu
```

Use `region: us` (the default) for `api.opsgenie.com`; select `eu` for
`api.eu.opsgenie.com`. Provider API keys and request payloads are put in
mode-`0600` temporary files and never curl command-line arguments or logs.
Test them explicitly with `notify-test --channel pagerduty` or
`notify-test --channel opsgenie`.

## Template variables

The ordinary failure and recovery templates receive:

- `{{service}}`, `{{event}}`, and `{{timestamp}}`
- `{{check_type}}`, `{{detail}}`, `{{http_status}}`, and `{{check_exit}}`
- `{{action_status}}`
- `{{severity}}` and `{{runbook_url}}` from `services[].notify` (the runbook
  value is empty when it is not configured)
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
# Test every channel eligible for service api with a synthetic failure.
bash ./service-watchdog.sh notify-test -c ./config.yaml -s api

# Test only Slack with recovery templates.
bash ./service-watchdog.sh notify-test -c ./config.yaml \
  --channel slack --event recovery

# Use watchdog-test as the synthetic service name and escalation templates.
bash ./service-watchdog.sh notify-test -c ./config.yaml \
  --channel all --event escalation
```

Outgoing subjects and channel text include `[TEST]`. The terminal output is a
`CHANNEL | RESULT | DETAIL` table. With `-s`, globally enabled channels not in
the service's `notify.channels` appear as `skipped | not routed`. Exit `0`
means every selected, eligible channel succeeded; `1` means at least one
failed; `2` indicates invalid config or that no selected eligible channel is
enabled.

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

## Remote HTTP remediation

Use `actions.http` to call a restart or orchestration API without embedding a
shell command. It runs after `actions.commands`, then Watchdog performs the
same optional `verify_after` health check. Cooldown, backoff, circuit breaker,
flapping protection, maintenance suppression, and `--dry-run` apply unchanged.

```yaml
services:
  - name: api
    check: {type: http, url: http://127.0.0.1:8080/health}
    actions:
      http:
        - method: POST
          url: https://portainer.example.com/api/restart
          headers:
            - name: Authorization
              value_env: WATCHDOG_PORTAINER_TOKEN
          body: '{"force":true}'
          success_status: [202, 204]
          timeout: 30
```

Only `POST`, `PUT`, `PATCH`, and `DELETE` are accepted. `success_status`
defaults to any 2xx response. Store credentials in `headers[].value_env` or
`body_env`; literal `body` is for non-secret data. Payloads and secret headers
are written to private temporary files and removed after each request.

## Restrict remediation with an allowlist

Legacy mode preserves existing configurations. In `enforce` mode, list every
exact executable/argument vector and exact remote HTTP method/URL pair used by
remediation.

```yaml
security:
  remediation_policy:
    mode: enforce
    allowed_commands:
      - command: [/usr/bin/systemctl, restart, api]
      - command: [/usr/bin/systemctl, restart, worker]
    allowed_http:
      - method: POST
        url: https://portainer.example.com/api/restart
```

Validation and execution reject relative/symlink executable paths, shebang
scripts, wrapper shells, and argument vectors absent from the allowlist. This
is a guardrail, not a sandbox: trusted binaries and privileged service
accounts still need careful filesystem permissions. The policy covers
`actions.commands`, `escalation.actions.commands`, and `actions.http`, not
health checks, conditions, or hooks.

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
