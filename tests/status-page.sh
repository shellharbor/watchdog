#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() { rm -rf -- "$TEST_DIRECTORY"; }
trap cleanup EXIT

for command_name in yq curl flock timeout date; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

touch "${TEST_DIRECTORY}/healthy"
cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
status_page:
  enabled: true
  output_directory: ${TEST_DIRECTORY}/status
  html_filename: index.html
  json_filename: status.json
  title: Test Status
  auto_refresh: 0
  uptime:
    enabled: true
    days: 4
    buckets: 4
history:
  enabled: true
  storage: jsonl
  path: ${TEST_DIRECTORY}/history
  rotation:
    mode: daily
    max_age_days: 0
services:
  - name: status-service
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
EOF

mkdir -p "${TEST_DIRECTORY}/history"
printf '{"timestamp":"%s","service":"status-service","state":"unavailable"}\n' "$(date -d '3 days ago' -Iseconds)" >"${TEST_DIRECTORY}/history/history_$(date -d '3 days ago' '+%Y-%m-%d').jsonl"
printf '{"timestamp":"%s","service":"status-service","state":"degraded"}\n' "$(date -d '2 days ago' -Iseconds)" >"${TEST_DIRECTORY}/history/history_$(date -d '2 days ago' '+%Y-%m-%d').jsonl"

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s status-service
[[ -f "${TEST_DIRECTORY}/status/index.html" && -f "${TEST_DIRECTORY}/status/status.json" ]]
grep -F '<title>Test Status</title>' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'status-service' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'Observed availability:' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'uptime-healthy' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'uptime-down' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'uptime-warning' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'uptime-unknown' "${TEST_DIRECTORY}/status/index.html" >/dev/null
[[ "$(grep -o '<span class="uptime-bar' "${TEST_DIRECTORY}/status/index.html" | wc -l)" == 4 ]]
grep -F '"overall_status": "operational"' "${TEST_DIRECTORY}/status/status.json" >/dev/null
tail -c 1 "${TEST_DIRECTORY}/status/index.html" | od -An -t x1 | grep -F '0a' >/dev/null

yq eval -i '.status_page.uptime.enabled = false' "${TEST_DIRECTORY}/config.yaml"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s status-service
if grep -F '<div class="uptime">' "${TEST_DIRECTORY}/status/index.html" >/dev/null; then
    printf 'Uptime bars were rendered when disabled.\n' >&2
    exit 1
fi

cat >"${TEST_DIRECTORY}/invalid-uptime.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
status_page:
  enabled: true
  output_directory: ${TEST_DIRECTORY}/status
  uptime:
    enabled: true
services:
  - name: status-service
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
EOF
set +e
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/invalid-uptime.yaml" >"${TEST_DIRECTORY}/invalid-uptime.out" 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" == 2 ]]
grep -F 'status_page.uptime.enabled requires history.enabled=true.' "${TEST_DIRECTORY}/invalid-uptime.out" >/dev/null

printf 'Status page test passed.\n'
