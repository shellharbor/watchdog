#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { printf 'notify-test failed: %s\n' "$1" >&2; exit 1; }

mkdir -p "$TEST_DIR/bin"
WATCHDOG_REAL_DATE="$(command -v date)"
export WATCHDOG_REAL_DATE
cat >"$TEST_DIR/bin/date" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
    '+%a') printf 'Mon\n' ;;
    '+%H:%M') printf '12:00\n' ;;
    *) exec "$WATCHDOG_REAL_DATE" "$@" ;;
esac
SHIM
cat >"$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
output_file='' upload_file='' url=''
while (( $# > 0 )); do
    case "$1" in
        --output) output_file="$2"; shift 2 ;;
        --upload-file) upload_file="$2"; shift 2 ;;
        *)
            [[ "$1" != *'[TEST]'* && "$1" != *recovered* && "$1" != *ESCALATION* ]] ||
                printf '%s\n' "$1" >>"$WATCHDOG_TEST_REQUESTS"
            url="$1"; shift ;;
    esac
done
[[ -z "$upload_file" ]] || cat "$upload_file" >>"$WATCHDOG_TEST_MAIL"
if [[ "${WATCHDOG_TEST_CURL_FAIL:-0}" == 1 ]]; then
    printf 'curl: failed to connect to %s\n' "$WATCHDOG_DISCORD_WEBHOOK_URL" >&2
    exit 7
fi
if [[ -n "$output_file" ]]; then
    if [[ "$url" == *sendMessage ]]; then printf '{"ok":true}' >"$output_file"; else printf 'ok' >"$output_file"; fi
fi
printf '200'
SHIM
chmod +x "$TEST_DIR/bin/curl" "$TEST_DIR/bin/date"
export PATH="$TEST_DIR/bin:$PATH"
export WATCHDOG_TEST_REQUESTS="$TEST_DIR/requests"
export WATCHDOG_TEST_MAIL="$TEST_DIR/mail"
export WD_TEST_SMTP='secret-smtp-value'
export WD_TEST_TELEGRAM='secret-telegram-value'
export WATCHDOG_DISCORD_WEBHOOK_URL='https://discord.example.test/secret-discord-value'
export WATCHDOG_SLACK_WEBHOOK_URL='https://slack.example.test/secret-slack-value'
export WD_TEST_NTFY='secret-ntfy-value'

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.test:465
      from: watchdog@example.test
      username: watchdog@example.test
      password_env: WD_TEST_SMTP
    recipients: [operator@example.test]
    failure:
      subject: "Failure {{service}}"
      body: "{{detail}} / {{incident_id}} / {{http_status}}"
    recovery:
      subject: "Recovery {{service}}"
      body: "Recovered {{service}}"
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WD_TEST_TELEGRAM
      chat_id: "123"
    discord:
      enabled: true
      webhook_url_env: WATCHDOG_DISCORD_WEBHOOK_URL
    slack:
      enabled: true
      webhook_url_env: WATCHDOG_SLACK_WEBHOOK_URL
    ntfy:
      enabled: true
      url: https://ntfy.example.test/topic
      token_env: WD_TEST_NTFY
services:
  - name: api
    check:
      type: command
      commands:
        - command: [false]
    maintenance:
      windows:
        - name: test-window
          days: mon
          time: "11:00-13:00"
YAML

bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" -s api \
    >"$TEST_DIR/all.out" 2>"$TEST_DIR/all.err" || fail 'all enabled channels should succeed'
[[ "$(grep -c ' | sent | ' "$TEST_DIR/all.out")" == 5 ]] || fail 'expected five successful channels'
grep -Fq '[TEST]' "$WATCHDOG_TEST_REQUESTS" || fail 'webhook marker missing'
(( $(grep -c '\[TEST\]' "$WATCHDOG_TEST_REQUESTS") >= 4 )) || fail 'not every webhook has a test marker'
grep -Fq '[TEST] This is a test notification from watchdog' "$WATCHDOG_TEST_MAIL" || fail 'email body marker missing'
subject_b64="$(awk -F '?' '/^Subject:/ {print $4; exit}' "$WATCHDOG_TEST_MAIL")"
printf '%s' "$subject_b64" | base64 -d | grep -Fq '[TEST] Failure api' || fail 'email subject marker missing'
grep -Fq 'result=test-notification-ignores-maintenance' "$TEST_DIR/all.err" || fail 'maintenance warning missing'
grep -Fq 'result=test-email-sent' "$TEST_DIR/watchdog.log" || fail 'email result missing from log'
[[ "$(grep -c 'result=test-webhook-sent' "$TEST_DIR/watchdog.log")" == 4 ]] || fail 'webhook results missing from log'
[[ ! -e "$TEST_DIR/state" && ! -e "$TEST_DIR/watchdog.lock" ]] || fail 'state or lock was created'
if grep -E -q 'secret-(smtp|telegram|discord|slack|ntfy)-value' "$TEST_DIR/watchdog.log" "$TEST_DIR/all.out" "$TEST_DIR/all.err"; then
    fail 'secret leaked to output or operational log'
fi

bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" --channel slack --event recovery \
    >"$TEST_DIR/recovery.out" || fail 'recovery test failed'
[[ "$(grep -c ' | sent | ' "$TEST_DIR/recovery.out")" == 1 ]] || fail 'channel filter failed'
grep -Fq '[TEST]' "$WATCHDOG_TEST_REQUESTS" || fail 'recovery marker missing'
grep -Fq 'recovered' "$WATCHDOG_TEST_REQUESTS" || fail 'recovery template was not used'

bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" -s api --channel email --event escalation \
    >"$TEST_DIR/escalation.out" || fail 'escalation test failed'
grep -Fq 'ESCALATION' "$WATCHDOG_TEST_MAIL" || fail 'escalation email template missing'

cp "$TEST_DIR/config.yaml" "$TEST_DIR/disabled.yaml"
yq eval -i '.notifications.webhooks.slack.enabled = false' "$TEST_DIR/disabled.yaml"
status=0
bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/disabled.yaml" --channel slack \
    >"$TEST_DIR/disabled.out" 2>"$TEST_DIR/disabled.err" || status=$?
[[ "$status" == 2 ]] || fail "disabled-only channel should exit 2, got ${status}"
grep -Fq 'slack | skipped | disabled' "$TEST_DIR/disabled.out" || fail 'disabled result missing'

status=0
(unset WATCHDOG_DISCORD_WEBHOOK_URL; bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" --channel discord) \
    >"$TEST_DIR/missing.out" 2>"$TEST_DIR/missing.err" || status=$?
[[ "$status" == 1 ]] || fail "missing secret should exit 1, got ${status}"
grep -Fq 'WATCHDOG_DISCORD_WEBHOOK_URL' "$TEST_DIR/missing.out" || fail 'missing variable name absent'
status=0
(unset WD_TEST_SMTP; bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" --channel email) \
    >"$TEST_DIR/missing-email.out" 2>"$TEST_DIR/missing-email.err" || status=$?
[[ "$status" == 1 ]] || fail "missing SMTP secret should exit 1, got ${status}"
grep -Fq 'WD_TEST_SMTP' "$TEST_DIR/missing-email.out" || fail 'missing SMTP variable name absent'

status=0
WATCHDOG_TEST_CURL_FAIL=1 bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" --channel discord \
    >"$TEST_DIR/failure.out" 2>"$TEST_DIR/failure.err" || status=$?
[[ "$status" == 1 ]] || fail "curl failure should exit 1, got ${status}"
grep -Fq 'curl exit 7' "$TEST_DIR/failure.out" || fail 'curl error absent'
if grep -Fq 'secret-discord-value' "$TEST_DIR/failure.out" "$TEST_DIR/watchdog.log"; then fail 'webhook URL secret leaked'; fi

for invalid_args in '--channel invalid' '--event invalid' '--dry-run'; do
    status=0
    # Intentionally split a fixed, local test vector into CLI arguments.
    read -r -a args <<<"$invalid_args"
    bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIR/config.yaml" "${args[@]}" >/dev/null 2>&1 || status=$?
    [[ "$status" == 2 ]] || fail "invalid arguments should exit 2: ${invalid_args}"
done

printf 'notify-test tests passed\n'
