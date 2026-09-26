#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_DIRECTORY"; }
trap cleanup EXIT

for command_name in yq flock timeout date; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

mkdir -p "$TEST_DIRECTORY/bin"
cat >"$TEST_DIRECTORY/bin/dig" <<'DIG'
#!/usr/bin/env bash
if [[ "${DNS_TEST_MODE:-ok}" == missing ]]; then exit 0; fi
printf '203.0.113.42\n'
DIG
cat >"$TEST_DIRECTORY/bin/ping" <<'PING'
#!/usr/bin/env bash
if [[ "${PING_TEST_MODE:-ok}" == loss ]]; then
    printf '2 packets transmitted, 1 received, 50%% packet loss, time 1000ms\n'
    printf 'rtt min/avg/max/mdev = 1.000/4.000/7.000/0.100 ms\n'
else
    printf '2 packets transmitted, 2 received, 0%% packet loss, time 1000ms\n'
    printf 'rtt min/avg/max/mdev = 1.000/2.000/3.000/0.100 ms\n'
fi
PING
cat >"$TEST_DIRECTORY/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args_file="${WATCHDOG_CURL_ARGS:?}"
payloads_file="${WATCHDOG_CURL_PAYLOADS:?}"
configs_file="${WATCHDOG_CURL_CONFIGS:?}"
config=''
payload=''
next_config=0
next_data=0
for argument in "$@"; do
    if (( next_config == 1 )); then config="$argument"; next_config=0; continue; fi
    if (( next_data == 1 )); then payload="$argument"; next_data=0; continue; fi
    case "$argument" in
        --config) next_config=1 ;;
        --data|--data-binary) next_data=1 ;;
    esac
done
printf '%s\n' "$*" >>"$args_file"
[[ -z "$config" ]] || { printf '%s\n' '---' >>"$configs_file"; cat "$config" >>"$configs_file"; }
if [[ "$payload" == @* ]]; then
    printf '%s\n' '---' >>"$payloads_file"
    cat "${payload#@}" >>"$payloads_file"
elif [[ -n "$payload" ]]; then
    printf '%s\n' "$payload" >>"$payloads_file"
fi
printf '202'
CURL
chmod +x "$TEST_DIRECTORY/bin/dig" "$TEST_DIRECTORY/bin/ping" "$TEST_DIRECTORY/bin/curl"

cat >"$TEST_DIRECTORY/config.yaml" <<EOF
settings:
  log_file: $TEST_DIRECTORY/watchdog.log
  lock_file: $TEST_DIRECTORY/watchdog.lock
  state_directory: $TEST_DIRECTORY/state
  default_attempts: 1
  default_retry_delay: 0
  default_action_cooldown: 0
notifications:
  webhooks:
    pagerduty:
      enabled: true
      routing_key_env: WD_PAGERDUTY_KEY
    opsgenie:
      enabled: true
      api_key_env: WD_OPSGENIE_KEY
      region: eu
security:
  remediation_policy:
    mode: legacy
services:
  - name: dns-record
    check:
      type: dns
      name: api.example.test
      record_type: A
      resolver: 192.0.2.53
      min_answers: 1
      expected_answers: [203.0.113.42]
      attempts: 1
  - name: icmp-host
    check:
      type: ping
      host: 203.0.113.42
      count: 2
      max_packet_loss_percent: 0
      max_avg_rtt_ms: 3
      attempts: 1
  - name: remote-api
    check:
      type: command
      commands:
        - command: [test, -f, $TEST_DIRECTORY/healthy]
      attempts: 1
    actions:
      cooldown: 0
      http:
        - url: https://portainer.example.test/api/restart
          method: POST
          headers:
            - name: Authorization
              value_env: WD_REMOTE_TOKEN
          body_env: WD_REMOTE_BODY
          success_status: [202]
EOF

export PATH="$TEST_DIRECTORY/bin:$PATH"
export WD_PAGERDUTY_KEY='pagerduty-secret'
export WD_OPSGENIE_KEY='opsgenie-secret'
export WD_REMOTE_TOKEN='remote-secret'
export WD_REMOTE_BODY='{"service":"remote-api","token":"remote-body-secret"}'
export WATCHDOG_CURL_ARGS="$TEST_DIRECTORY/curl-args.log"
export WATCHDOG_CURL_PAYLOADS="$TEST_DIRECTORY/curl-payloads.log"
export WATCHDOG_CURL_CONFIGS="$TEST_DIRECTORY/curl-configs.log"

bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIRECTORY/config.yaml" >/dev/null
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" -s dns-record >/dev/null
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" -s icmp-host >/dev/null
bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIRECTORY/config.yaml" --channel pagerduty --event escalation >"$TEST_DIRECTORY/pagerduty-test.out"
bash "$ROOT_DIR/service-watchdog.sh" notify-test -c "$TEST_DIRECTORY/config.yaml" --channel opsgenie --event recovery >"$TEST_DIRECTORY/opsgenie-test.out"
grep -Fq 'pagerduty | sent | HTTP 202' "$TEST_DIRECTORY/pagerduty-test.out"
grep -Fq 'opsgenie | sent | HTTP 202' "$TEST_DIRECTORY/opsgenie-test.out"
grep -Fq '[TEST]' "$WATCHDOG_CURL_PAYLOADS"

status=0
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" -s remote-api >/dev/null || status=$?
[[ "$status" == 1 ]]
grep -Fq '"event_action":"trigger"' "$WATCHDOG_CURL_PAYLOADS"
grep -Fq '"alias":"watchdog-remote-api-' "$WATCHDOG_CURL_PAYLOADS"
grep -Fq '"service":"remote-api","token":"remote-body-secret"' "$WATCHDOG_CURL_PAYLOADS"
grep -Fq 'Authorization: remote-secret' "$WATCHDOG_CURL_CONFIGS"
grep -Fq 'Authorization: GenieKey opsgenie-secret' "$WATCHDOG_CURL_CONFIGS"
if grep -Eq 'pagerduty-secret|opsgenie-secret|remote-secret|remote-body-secret' "$WATCHDOG_CURL_ARGS" "$TEST_DIRECTORY/watchdog.log"; then
    printf 'A remote/on-call secret reached curl argv or the watchdog log.\n' >&2
    exit 1
fi

touch "$TEST_DIRECTORY/healthy"
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" -s remote-api >/dev/null
grep -Fq '"event_action":"resolve"' "$WATCHDOG_CURL_PAYLOADS"
grep -Fq '/close?identifierType=alias' "$WATCHDOG_CURL_ARGS"

status=0
DNS_TEST_MODE=missing bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" -s dns-record >/dev/null || status=$?
[[ "$status" == 1 ]]
grep -Fq 'answers=0 below min_answers=1' "$TEST_DIRECTORY/watchdog.log"

status=0
PING_TEST_MODE=loss bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" -s icmp-host >/dev/null || status=$?
[[ "$status" == 1 ]]
grep -Fq 'packet_loss=50% exceeds max_packet_loss_percent=0' "$TEST_DIRECTORY/watchdog.log"

cp "$TEST_DIRECTORY/config.yaml" "$TEST_DIRECTORY/enforce.yaml"
yq eval -i '.security.remediation_policy = {"mode":"enforce","allowed_http":[{"method":"POST","url":"https://portainer.example.test/api/restart"}]}' "$TEST_DIRECTORY/enforce.yaml"
bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIRECTORY/enforce.yaml" >/dev/null
yq eval -i '.security.remediation_policy.allowed_http[0].url = "https://elsewhere.example.test/restart"' "$TEST_DIRECTORY/enforce.yaml"
status=0
bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIRECTORY/enforce.yaml" >"$TEST_DIRECTORY/enforce.out" 2>&1 || status=$?
[[ "$status" == 2 ]]
grep -Fq '.services[2].actions.http[0]' "$TEST_DIRECTORY/enforce.out"

printf 'Network, on-call, and remote remediation tests passed.\n'
