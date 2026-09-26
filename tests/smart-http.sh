#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"
SERVER_PID=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || wait "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

for command_name in "$PYTHON_BIN" curl yq flock timeout; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

PORT="$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

"$PYTHON_BIN" - "$PORT" "${TEST_DIRECTORY}/requests.log" <<'PY' >"${TEST_DIRECTORY}/server.log" 2>&1 &
import http.server
import sys
import time

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], "a", encoding="utf-8") as out:
            out.write(f"{self.path}\t{self.headers.get('X-Api-Key', '')}\n")
        if self.path == "/slow":
            time.sleep(0.30)
        if self.path == "/wrong-content":
            content_type, body = "text/plain", b'{"status":"ok"}'
        elif self.path == "/wrong-body":
            content_type, body = "application/json", b'{"status":"not-ready"}'
        else:
            content_type, body = "application/json; charset=utf-8", b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
SERVER_PID=$!

export WATCHDOG_SMART_HTTP_TOKEN='test-smart-http-secret'

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
services:
  - name: smart-ok
    check:
      type: http
      url: http://127.0.0.1:${PORT}/ok
      headers:
        - name: Accept
          value: application/json
        - name: X-Api-Key
          value_env: WATCHDOG_SMART_HTTP_TOKEN
      expect:
        content_type: application/json
        body_regex: '"status"[[:space:]]*:[[:space:]]*"ok"'
        max_total_ms: 1000
    actions: {commands: []}
  - name: slow-api
    check:
      type: http
      url: http://127.0.0.1:${PORT}/slow
      expect: {max_total_ms: 50}
    actions:
      commands:
        - command: [touch, ${TEST_DIRECTORY}/slow-remediation-ran]
  - name: wrong-content
    check:
      type: http
      url: http://127.0.0.1:${PORT}/wrong-content
      expect: {content_type: application/json}
    actions: {commands: []}
  - name: wrong-body
    check:
      type: http
      url: http://127.0.0.1:${PORT}/wrong-body
      expect: {body_regex: '"status"[[:space:]]*:[[:space:]]*"ok"'}
    actions: {commands: []}
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml"
status=$?
set -e
[[ "$status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/smart-ok.state")" == healthy ]]
[[ "$(<"${TEST_DIRECTORY}/state/slow-api.state")" == degraded ]]
[[ "$(<"${TEST_DIRECTORY}/state/wrong-content.state")" == unavailable ]]
[[ "$(<"${TEST_DIRECTORY}/state/wrong-body.state")" == unavailable ]]
[[ ! -e "${TEST_DIRECTORY}/slow-remediation-ran" ]]
grep -F $'/ok\ttest-smart-http-secret' "${TEST_DIRECTORY}/requests.log" >/dev/null
if grep -F 'test-smart-http-secret' "${TEST_DIRECTORY}/watchdog.log" >/dev/null; then
    printf 'Secret header value leaked into the operational log.\n' >&2
    exit 1
fi
grep -F 'watchdog_service_http_last_total_seconds{service="slow-api",check_type="http"} ' "${TEST_DIRECTORY}/metrics/watchdog.prom" >/dev/null
grep -F 'watchdog_service_http_latency_slo_seconds{service="slow-api",check_type="http"} 0.050' "${TEST_DIRECTORY}/metrics/watchdog.prom" >/dev/null

sed -i 's/max_total_ms: 50/max_total_ms: 1000/' "${TEST_DIRECTORY}/config.yaml"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s slow-api
[[ "$(<"${TEST_DIRECTORY}/state/slow-api.state")" == healthy ]]

unset WATCHDOG_SMART_HTTP_TOKEN
set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s smart-ok
status=$?
set -e
[[ "$status" == 1 ]]
grep -F 'missing HTTP header environment variable WATCHDOG_SMART_HTTP_TOKEN' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

cat >"${TEST_DIRECTORY}/invalid.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/invalid.log
  lock_file: ${TEST_DIRECTORY}/invalid.lock
  state_directory: ${TEST_DIRECTORY}/invalid-state
services:
  - name: broken-regex
    check:
      type: http
      url: http://127.0.0.1:${PORT}/ok
      expect: {body_regex: '['}
EOF
set +e
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/invalid.yaml" >"${TEST_DIRECTORY}/invalid.out" 2>&1
status=$?
set -e
[[ "$status" == 2 ]]
grep -F 'services[0].check.expect.body_regex' "${TEST_DIRECTORY}/invalid.out" >/dev/null

printf 'Smart HTTP test passed.\n'
