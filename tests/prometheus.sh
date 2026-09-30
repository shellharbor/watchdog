#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() { rm -rf -- "$TEST_DIRECTORY"; }
trap cleanup EXIT

for command_name in yq curl flock timeout; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

mkdir -p "${TEST_DIRECTORY}/metrics"
touch "${TEST_DIRECTORY}/healthy"
cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
metrics:
  enabled: true
  textfile_directory: ${TEST_DIRECTORY}/metrics
  filename: watchdog.prom
  prefix: watchdog
  static_labels:
    instance: test-host
  heartbeat:
    enabled: true
services:
  - name: prometheus-check
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
EOF

# A targeted run before any full monitor run cannot establish a scheduler
# heartbeat. It may still export selected service metrics.
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s prometheus-check
METRICS_FILE="${TEST_DIRECTORY}/metrics/watchdog.prom"
if grep -F 'watchdog_heartbeat_timestamp_seconds' "$METRICS_FILE" >/dev/null; then
    printf 'Initial targeted run unexpectedly established a scheduler heartbeat.\n' >&2
    exit 1
fi

before_heartbeat="$(date '+%s')"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml"
after_heartbeat="$(date '+%s')"
[[ -f "$METRICS_FILE" ]]
grep -F '# HELP watchdog_heartbeat_timestamp_seconds Unix timestamp of the latest completed full Watchdog run' "$METRICS_FILE" >/dev/null
grep -F '# TYPE watchdog_heartbeat_timestamp_seconds gauge' "$METRICS_FILE" >/dev/null
heartbeat_timestamp="$(awk '/^watchdog_heartbeat_timestamp_seconds\{instance="test-host"\} / { print $2 }' "$METRICS_FILE")"
[[ "$heartbeat_timestamp" =~ ^[0-9]+$ ]]
(( heartbeat_timestamp >= before_heartbeat && heartbeat_timestamp <= after_heartbeat ))
grep -F '# HELP watchdog_service_state' "$METRICS_FILE" >/dev/null
grep -F 'watchdog_service_state{service="prometheus-check",check_type="command",instance="test-host"} 0' "$METRICS_FILE" >/dev/null
grep -F 'watchdog_service_last_check_timestamp' "$METRICS_FILE" >/dev/null
tail -c 1 "$METRICS_FILE" | od -An -t x1 | grep -F '0a' >/dev/null

# A completed unhealthy run still proves the scheduler completed; service-state
# alerts, rather than the heartbeat, carry the incident signal.
rm -f -- "${TEST_DIRECTORY}/healthy"
if bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml"; then
    printf 'Expected unavailable service run to return 1.\n' >&2
    exit 1
else
    exit_status=$?
fi
(( exit_status == 1 ))
failure_heartbeat_timestamp="$(awk '/^watchdog_heartbeat_timestamp_seconds\{instance="test-host"\} / { print $2 }' "$METRICS_FILE")"
[[ "$failure_heartbeat_timestamp" =~ ^[0-9]+$ ]]

# A manual partial run must not make the scheduler heartbeat look fresh.
if bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s prometheus-check; then
    printf 'Expected targeted unavailable service run to return 1.\n' >&2
    exit 1
else
    exit_status=$?
fi
(( exit_status == 1 ))
partial_heartbeat_timestamp="$(awk '/^watchdog_heartbeat_timestamp_seconds\{instance="test-host"\} / { print $2 }' "$METRICS_FILE")"
if [[ "$partial_heartbeat_timestamp" != "$failure_heartbeat_timestamp" ]]; then
    printf 'Targeted run unexpectedly refreshed or removed the scheduler heartbeat.\n' >&2
    exit 1
fi

# The scheduler metric needs no service label and remains valid without any
# configured static labels.
touch "${TEST_DIRECTORY}/healthy"
cat >"${TEST_DIRECTORY}/no-labels.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog-no-labels.log
  lock_file: ${TEST_DIRECTORY}/watchdog-no-labels.lock
  state_directory: ${TEST_DIRECTORY}/state-no-labels
  default_attempts: 1
  default_retry_delay: 0
metrics:
  enabled: true
  textfile_directory: ${TEST_DIRECTORY}/metrics
  filename: watchdog.prom
  prefix: watchdog
  heartbeat:
    enabled: true
services:
  - name: no-labels-check
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
EOF
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/no-labels.yaml"
grep -E '^watchdog_heartbeat_timestamp_seconds [0-9]+$' "$METRICS_FILE" >/dev/null
if grep -F 'watchdog_heartbeat_timestamp_seconds{' "$METRICS_FILE" >/dev/null; then
    printf 'Heartbeat unexpectedly has labels without configured static labels.\n' >&2
    exit 1
fi

# The checked-in observability files stay parseable and retain their key alert.
yq eval '.' "${PROJECT_DIR}/observability/grafana/watchdog-overview.json" >/dev/null
yq eval '.groups[0].rules[] | select(.alert == "WatchdogHeartbeatMissing") | .expr' \
    "${PROJECT_DIR}/observability/prometheus/watchdog-alerts.yml" | grep -F 'watchdog_heartbeat_timestamp_seconds' >/dev/null
yq eval '.routes[0].matchers[0]' "${PROJECT_DIR}/observability/alertmanager/watchdog-route.example.yml" | grep -F 'component="watchdog"' >/dev/null

printf 'Prometheus metrics test passed.\n'
