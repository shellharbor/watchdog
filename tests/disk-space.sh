#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { printf 'disk-space test failed: %s\n' "$1" >&2; exit 1; }

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/df" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"$DISK_TEST_DF_CALLS"
case "${DISK_TEST_MODE:-healthy}" in
    healthy) printf '1B-blocks Avail\n107374182400 32212254720\n' ;;
    low_gb) printf '1B-blocks Avail\n53687091200 5368709120\n' ;;
    low_percent) printf '1B-blocks Avail\n214748364800 16106127360\n' ;;
    full) printf '1B-blocks Avail\n107374182400 0\n' ;;
    slow) sleep 3; printf '1B-blocks Avail\n107374182400 32212254720\n' ;;
    error) printf 'df: missing filesystem\n' >&2; exit 1 ;;
    *) exit 2 ;;
esac
SHIM
cat >"$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
output_file='' upload_file='' endpoint=''
for argument in "$@"; do
    [[ "$argument" != *'low disk space'* ]] || printf '%s\n' "$argument" >>"$DISK_TEST_PAYLOADS"
done
while (( $# > 0 )); do
    case "$1" in
        --output) output_file="$2"; shift 2 ;;
        --upload-file) upload_file="$2"; shift 2 ;;
        --url) endpoint="$2"; shift 2 ;;
        *) endpoint="$1"; shift ;;
    esac
done
if [[ -n "$upload_file" ]]; then
    printf 'email\n' >>"$DISK_TEST_CALLS"
    cat "$upload_file" >>"$DISK_TEST_MAIL"
    exit 0
fi
case "$endpoint" in
    *api.telegram.org*) channel=telegram; printf '{"ok":true}' >"$output_file" ;;
    *discord.example.test*) channel=discord; printf 'ok' >"$output_file" ;;
    *slack.example.test*) channel=slack; printf 'ok' >"$output_file" ;;
    *ntfy.example.test*) channel=ntfy; printf 'ok' >"$output_file" ;;
    *) exit 3 ;;
esac
printf '%s\n' "$channel" >>"$DISK_TEST_CALLS"
printf '200'
SHIM
chmod +x "$TEST_DIR/bin/df" "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"
export DISK_TEST_DF_CALLS="$TEST_DIR/df-calls"
export DISK_TEST_CALLS="$TEST_DIR/curl-calls"
export DISK_TEST_PAYLOADS="$TEST_DIR/payloads"
export DISK_TEST_MAIL="$TEST_DIR/mail"
export WD_DISK_SMTP_PASSWORD='fake-password'
export WD_DISK_TELEGRAM_TOKEN='fake-telegram-token'
export WD_DISK_DISCORD_URL='https://discord.example.test/secret'
export WD_DISK_SLACK_URL='https://slack.example.test/secret'
export WD_DISK_NTFY_TOKEN='fake-ntfy-token'
: >"$DISK_TEST_DF_CALLS"
: >"$DISK_TEST_CALLS"
: >"$DISK_TEST_PAYLOADS"
: >"$DISK_TEST_MAIL"

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
  default_attempts: 1
  default_retry_delay: 0
notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.test:465
      from: watchdog@example.test
      username: watchdog@example.test
      password_env: WD_DISK_SMTP_PASSWORD
    recipients: [operator@example.test]
    failure:
      subject: "Disk alert {{service}}"
      body: "{{detail}}"
    recovery:
      subject: "Disk recovered {{service}}"
      body: "{{detail}}"
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WD_DISK_TELEGRAM_TOKEN
      chat_id: "123"
    discord:
      enabled: true
      webhook_url_env: WD_DISK_DISCORD_URL
    slack:
      enabled: true
      webhook_url_env: WD_DISK_SLACK_URL
    ntfy:
      enabled: true
      url: https://ntfy.example.test/topic
      token_env: WD_DISK_NTFY_TOKEN
services:
  - name: root-disk
    check:
      type: disk
      path: /
      min_free_gb: 10
      min_free_percent: 10
YAML

bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" >/dev/null || fail 'valid disk config rejected'
[[ ! -s "$DISK_TEST_DF_CALLS" && ! -e "$TEST_DIR/state" ]] || fail 'validate ran df or created state'

DISK_TEST_MODE=healthy bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || fail 'healthy disk rejected'
[[ "$(<"$TEST_DIR/state/root-disk.state")" == healthy ]] || fail 'healthy state missing'
[[ ! -s "$DISK_TEST_CALLS" ]] || fail 'healthy disk sent notifications'

status=0
DISK_TEST_MODE=low_gb bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || status=$?
[[ "$status" == 1 ]] || fail "low GiB exit should be 1, got ${status}"
[[ "$(<"$TEST_DIR/state/root-disk.state")" == unavailable ]] || fail 'low GiB state missing'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 5 ]] || fail 'failure did not notify all five channels'
grep -Fq 'low disk space' "$DISK_TEST_MAIL" || fail 'email lacks disk detail'
grep -Fq 'low disk space' "$DISK_TEST_PAYLOADS" || fail 'webhooks lack disk detail'
grep -Fq 'free_percent=10.00' "$TEST_DIR/watchdog.log" || fail 'free percentage was not calculated'

status=0
DISK_TEST_MODE=low_percent bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || status=$?
[[ "$status" == 1 ]] || fail 'low percent exit should be 1'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 5 ]] || fail 'outage repeated notifications'
grep -Fq 'free_percent=7.50' "$TEST_DIR/watchdog.log" || fail 'low percent detail missing'

status=0
DISK_TEST_MODE=full bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || status=$?
[[ "$status" == 1 ]] || fail 'full disk exit should be 1'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 5 ]] || fail 'full disk repeated notifications'
grep -Fq 'free_gb=0.00 free_percent=0.00' "$TEST_DIR/watchdog.log" || fail 'zero available bytes not reported'

DISK_TEST_MODE=healthy bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || fail 'disk recovery rejected'
[[ "$(<"$TEST_DIR/state/root-disk.state")" == healthy ]] || fail 'recovery state missing'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 10 ]] || fail 'recovery did not notify all five channels'

status=0
DISK_TEST_MODE=low_gb bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" -n >/dev/null || status=$?
[[ "$status" == 1 ]] || fail 'dry-run should report low disk'
[[ "$(<"$TEST_DIR/state/root-disk.state")" == healthy ]] || fail 'dry-run changed state'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 10 ]] || fail 'dry-run sent notifications'

cp "$TEST_DIR/config.yaml" "$TEST_DIR/timeout.yaml"
yq eval -i '.services[0].check.timeout = 1' "$TEST_DIR/timeout.yaml"
status=0
DISK_TEST_MODE=slow bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/timeout.yaml" -n >/dev/null || status=$?
[[ "$status" == 1 ]] || fail 'timed-out df should be unhealthy'
[[ "$(<"$TEST_DIR/state/root-disk.state")" == healthy ]] || fail 'timed-out dry-run changed state'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 10 ]] || fail 'timed-out dry-run sent notifications'

status=0
DISK_TEST_MODE=error bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || status=$?
[[ "$status" == 1 ]] || fail 'df error should be unhealthy'
[[ "$(wc -l <"$DISK_TEST_CALLS")" == 15 ]] || fail 'df error did not notify'
grep -Fq 'reason=filesystem-unavailable' "$TEST_DIR/watchdog.log" || fail 'df error detail missing'

for invalid_case in missing_threshold relative_path high_percent negative_gb; do
    cp "$TEST_DIR/config.yaml" "$TEST_DIR/invalid.yaml"
    case "$invalid_case" in
        missing_threshold) yq eval -i 'del(.services[0].check.min_free_gb, .services[0].check.min_free_percent)' "$TEST_DIR/invalid.yaml" ;;
        relative_path) yq eval -i '.services[0].check.path = "relative"' "$TEST_DIR/invalid.yaml" ;;
        high_percent) yq eval -i '.services[0].check.min_free_percent = 101' "$TEST_DIR/invalid.yaml" ;;
        negative_gb) yq eval -i '.services[0].check.min_free_gb = -1' "$TEST_DIR/invalid.yaml" ;;
    esac
    status=0
    bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/invalid.yaml" >"$TEST_DIR/invalid.out" 2>&1 || status=$?
    [[ "$status" == 2 ]] || fail "${invalid_case} should fail validation"
    grep -Fq 'services[0].check' "$TEST_DIR/invalid.out" || fail "${invalid_case} error lacks field path"
done

cat >"$TEST_DIR/only-if.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/only-if.log"
  lock_file: "$TEST_DIR/only-if.lock"
  state_directory: "$TEST_DIR/only-if-state"
services:
  - name: gated
    check:
      type: command
      commands:
        - command: [true]
    only_if:
      - type: filesystem
        path: /
        min_free_percent: 20
YAML
DISK_TEST_MODE=healthy bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/only-if.yaml" >/dev/null || fail 'healthy filesystem condition rejected'
[[ "$(<"$TEST_DIR/only-if-state/gated.state")" == healthy ]] || fail 'filesystem condition did not pass'
DISK_TEST_MODE=low_percent bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/only-if.yaml" >/dev/null || fail 'blocked filesystem condition run failed'
grep -Fq 'service=gated only_if=false' "$TEST_DIR/only-if.log" || fail 'filesystem condition used wrong free percentage'

printf 'Disk-space tests passed.\n'
