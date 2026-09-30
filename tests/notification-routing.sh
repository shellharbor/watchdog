#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() { printf 'notification-routing failed: %s\n' "$1" >&2; exit 1; }

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

payload=''
write_out=0
for ((index = 1; index <= $#; index++)); do
    case "${!index}" in
        --output)
            next=$((index + 1))
            printf '%s' '{"ok":true}' >"${!next}"
            ;;
        --write-out) write_out=1 ;;
        --data|--data-binary)
            next=$((index + 1))
            payload="${!next}"
            if [[ "$payload" == @* ]]; then
                payload="$(<"${payload#@}")"
            fi
            ;;
        --upload-file)
            next=$((index + 1))
            payload="$(<"${!next}")"
            ;;
    esac
done
[[ -z "$payload" ]] || printf '%s\n' "$payload" >>"$WATCHDOG_ROUTING_PAYLOADS"
(( write_out == 0 )) || printf '200'
CURL
chmod 0755 "$TEST_DIR/bin/curl"

export PATH="$TEST_DIR/bin:$PATH"
export WATCHDOG_ROUTING_PAYLOADS="$TEST_DIR/payloads.log"
export WD_ROUTING_SMTP='secret-smtp-value'
export WD_ROUTING_TELEGRAM='secret-telegram-value'
export WD_ROUTING_DISCORD='https://discord.example.test/secret-discord-value'
export WD_ROUTING_SLACK='https://slack.example.test/secret-slack-value'
export WD_ROUTING_NTFY='secret-ntfy-value'
export WD_ROUTING_PAGERDUTY='secret-pagerduty-value'
export WD_ROUTING_OPSGENIE='secret-opsgenie-value'

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
  default_attempts: 1
  default_retry_delay: 0
  default_action_cooldown: 0
notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.test:465
      from: watchdog@example.test
      username: watchdog@example.test
      password_env: WD_ROUTING_SMTP
    recipients: [operator@example.test]
    failure:
      subject: "[{{severity}}] {{service}} unavailable"
      body: "severity={{severity}} runbook={{runbook_url}}"
    recovery:
      subject: "[{{severity}}] {{service}} recovered"
      body: "severity={{severity}} runbook={{runbook_url}}"
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WD_ROUTING_TELEGRAM
      chat_id: "123"
    discord:
      enabled: true
      webhook_url_env: WD_ROUTING_DISCORD
    slack:
      enabled: true
      webhook_url_env: WD_ROUTING_SLACK
    ntfy:
      enabled: true
      url: https://ntfy.example.test/routing
      token_env: WD_ROUTING_NTFY
    pagerduty:
      enabled: true
      routing_key_env: WD_ROUTING_PAGERDUTY
    opsgenie:
      enabled: true
      api_key_env: WD_ROUTING_OPSGENIE
services:
  - name: payments-api
    check:
      type: command
      commands:
        - command: [false]
    notify:
      channels: [email, pagerduty, opsgenie]
      severity: warning
      runbook_url: https://runbooks.example.test/payments-api
YAML

status=0
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" -s payments-api >/dev/null 2>&1 || status=$?
[[ "$status" == 1 ]] || fail "failure run should exit 1, got ${status}"
[[ "$(grep -c 'result=email-sent event=failure' "$TEST_DIR/watchdog.log")" == 1 ]] || fail 'routed email was not sent'
[[ "$(grep -c 'result=webhook-sent event=failure' "$TEST_DIR/watchdog.log")" == 2 ]] || fail 'only routed webhooks should be sent'
grep -Fq 'severity=warning runbook=https://runbooks.example.test/payments-api' "$WATCHDOG_ROUTING_PAYLOADS" || fail 'email template context missing'
grep -Fq '"severity":"warning"' "$WATCHDOG_ROUTING_PAYLOADS" || fail 'PagerDuty severity missing'
grep -Fq '"custom_details":{"runbook_url":"https://runbooks.example.test/payments-api"}' "$WATCHDOG_ROUTING_PAYLOADS" || fail 'PagerDuty runbook missing'
grep -Fq '"priority":"P3"' "$WATCHDOG_ROUTING_PAYLOADS" || fail 'Opsgenie priority mapping missing'
grep -Fq '"details":{"runbook_url":"https://runbooks.example.test/payments-api"}' "$WATCHDOG_ROUTING_PAYLOADS" || fail 'Opsgenie runbook missing'
if grep -E -q 'secret-(smtp|telegram|discord|slack|ntfy|pagerduty|opsgenie)-value' "$TEST_DIR/watchdog.log"; then
    fail 'secret leaked to operational log'
fi

bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" -s payments-api --channel all \
    >"$TEST_DIR/notify-test.out" 2>"$TEST_DIR/notify-test.err" || fail 'routed notify-test should succeed'
[[ "$(grep -c ' | sent | ' "$TEST_DIR/notify-test.out")" == 3 ]] || fail 'notify-test should deliver only three routed channels'
[[ "$(grep -c ' | skipped | not routed' "$TEST_DIR/notify-test.out")" == 4 ]] || fail 'notify-test should identify unrouted channels'

status=0
bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" -s payments-api --channel telegram \
    >"$TEST_DIR/unrouted.out" 2>"$TEST_DIR/unrouted.err" || status=$?
[[ "$status" == 2 ]] || fail "unrouted-only notify-test should exit 2, got ${status}"
grep -Fq 'telegram | skipped | not routed' "$TEST_DIR/unrouted.out" || fail 'unrouted result missing'

# Notification routing is a normal service field and must inherit through the
# default deep template merge without re-enabling every global provider.
cp "$TEST_DIR/config.yaml" "$TEST_DIR/template-routing.yaml"
yq eval -i '
    .templates.route_defaults = {
      "notify": {
        "channels": ["email"],
        "severity": "info",
        "runbook_url": "https://runbooks.example.test/template-api"
      }
    } |
    .services[0].name = "template-api" |
    .services[0].template = "route_defaults" |
    del(.services[0].notify)
' "$TEST_DIR/template-routing.yaml"
: >"$WATCHDOG_ROUTING_PAYLOADS"
status=0
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/template-routing.yaml" -s template-api >/dev/null 2>&1 || status=$?
[[ "$status" == 1 ]] || fail "template-routed failure run should exit 1, got ${status}"
grep -Fq 'severity=info runbook=https://runbooks.example.test/template-api' "$WATCHDOG_ROUTING_PAYLOADS" ||
    fail 'template-inherited notification context missing'
if grep -E -q '"routing_key"|"message":"' "$WATCHDOG_ROUTING_PAYLOADS"; then
    fail 'template routing did not suppress non-email providers'
fi

printf 'Notification routing test passed.\n'
