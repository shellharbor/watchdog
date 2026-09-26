#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"
SERVER_PID=""
FIRST_PID=""
cleanup() {
    [[ -z "$FIRST_PID" ]] || { kill "$FIRST_PID" 2>/dev/null || true; wait "$FIRST_PID" 2>/dev/null || true; }
    [[ -z "$SERVER_PID" ]] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT
for command_name in yq curl flock timeout python3; do
    command -v "$command_name" >/dev/null || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

mkdir -p "${TEST_DIRECTORY}/bin"
export TEST_CLOCK_FILE="${TEST_DIRECTORY}/clock"
cat >"${TEST_DIRECTORY}/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" == 1 && "$1" == '+%s' ]]; then
    /usr/bin/cat "$TEST_CLOCK_FILE"
else
    /usr/bin/date "$@"
fi
EOF
chmod +x "${TEST_DIRECTORY}/bin/date"
export PATH="${TEST_DIRECTORY}/bin:${PATH}"
set_clock() { printf '%s\n' "$1" >"$TEST_CLOCK_FILE"; }
set_clock 3000

cat >"${TEST_DIRECTORY}/server.py" <<'PY'
import http.server
import os

directory = os.environ["TEST_DIRECTORY"]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        marker = "live" if self.path == "/liveness" else "ready" if self.path == "/readiness" else "missing"
        with open(os.path.join(directory, "requests"), "a", encoding="utf-8") as stream:
            stream.write(self.path + "\n")
        self.send_response(200 if os.path.exists(os.path.join(directory, marker)) else 503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(directory, "port"), "w", encoding="utf-8") as stream:
    stream.write(str(server.server_port))
server.serve_forever()
PY
export TEST_DIRECTORY
python3 "${TEST_DIRECTORY}/server.py" &
SERVER_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    [[ ! -s "${TEST_DIRECTORY}/port" ]] || break
    sleep 0.05
done
[[ -s "${TEST_DIRECTORY}/port" ]]
port="$(<"${TEST_DIRECTORY}/port")"

cat >"${TEST_DIRECTORY}/restore-live" <<EOF
#!/usr/bin/env bash
touch "${TEST_DIRECTORY}/market-action" "${TEST_DIRECTORY}/live"
EOF
chmod +x "${TEST_DIRECTORY}/restore-live"
cat >"${TEST_DIRECTORY}/record-recovery" <<EOF
#!/usr/bin/env bash
if [[ "\$WATCHDOG_SERVICE" == market-data ]]; then touch "${TEST_DIRECTORY}/recovered"; fi
EOF
chmod +x "${TEST_DIRECTORY}/record-recovery"
cat >"${TEST_DIRECTORY}/health.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/health.log
  lock_file: ${TEST_DIRECTORY}/health.lock
  state_directory: ${TEST_DIRECTORY}/health-state
  default_attempts: 1
  default_retry_delay: 0
hooks:
  on_recovery:
    - command: [${TEST_DIRECTORY}/record-recovery]
metrics:
  enabled: true
  textfile_directory: ${TEST_DIRECTORY}/metrics
  filename: watchdog.prom
  prefix: watchdog
services:
  - name: postgres
    check:
      type: command
      commands:
        - command: [/usr/bin/test, -f, ${TEST_DIRECTORY}/pg-up]
  - name: market-data
    depends_on:
      - name: postgres
        required: true
    health:
      liveness: {type: http, url: 'http://127.0.0.1:${port}/liveness', attempts: 1}
      readiness: {type: http, url: 'http://127.0.0.1:${port}/readiness', attempts: 1}
    actions:
      cooldown: 0
      commands:
        - command: [${TEST_DIRECTORY}/restore-live]
EOF

run_health() {
    local code=0
    bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/health.yaml" >/dev/null 2>"${TEST_DIRECTORY}/stderr" || code=$?
    [[ "$code" == "$1" ]] || { printf 'Health run exited %s; expected %s\n' "$code" "$1" >&2; /usr/bin/cat "${TEST_DIRECTORY}/stderr" >&2; exit 1; }
}

# A failed required dependency blocks the downstream check and remediation.
run_health 1
[[ "$(<"${TEST_DIRECTORY}/health-state/market-data.state")" == dependency_failed ]]
[[ ! -e "${TEST_DIRECTORY}/market-action" ]]
[[ ! -e "${TEST_DIRECTORY}/requests" ]]
grep -F '"blocked_by":"postgres"' "${TEST_DIRECTORY}/health-state/market-data.incident.json" >/dev/null

# Post-remediation liveness passes while readiness is still down.
touch "${TEST_DIRECTORY}/pg-up"
set_clock 3010
run_health 1
[[ -e "${TEST_DIRECTORY}/market-action" ]]
[[ "$(<"${TEST_DIRECTORY}/health-state/market-data.state")" == recovering ]]
[[ ! -e "${TEST_DIRECTORY}/recovered" ]]
grep -F '"phase":"recovering"' "${TEST_DIRECTORY}/health-state/market-data.incident.json" >/dev/null
grep -F '"attempts":1' "${TEST_DIRECTORY}/health-state/market-data.incident.json" >/dev/null
[[ "$(grep -c '^/liveness$' "${TEST_DIRECTORY}/requests")" == 2 ]]
[[ "$(grep -c '^/readiness$' "${TEST_DIRECTORY}/requests")" == 1 ]]

set_clock 3020
run_health 1
[[ "$(<"${TEST_DIRECTORY}/health-state/market-data.state")" == recovering ]]
[[ ! -e "${TEST_DIRECTORY}/recovered" ]]
touch "${TEST_DIRECTORY}/ready"
set_clock 3030
run_health 0
[[ "$(<"${TEST_DIRECTORY}/health-state/market-data.state")" == healthy ]]
[[ -e "${TEST_DIRECTORY}/recovered" ]]
[[ "$(wc -l <"${TEST_DIRECTORY}/health-state/market-data.incident-history.jsonl")" == 1 ]]
grep -F '"active":false' "${TEST_DIRECTORY}/health-state/market-data.incident-history.jsonl" >/dev/null
grep -F '"duration_seconds":30' "${TEST_DIRECTORY}/health-state/market-data.incident-history.jsonl" >/dev/null
grep -F '"remediation_result":"liveness-restored-readiness-pending"' "${TEST_DIRECTORY}/health-state/market-data.incident-history.jsonl" >/dev/null
grep -F '# TYPE watchdog_service_blocked_dependency_total counter' "${TEST_DIRECTORY}/metrics/watchdog.prom" >/dev/null
grep -F '# TYPE watchdog_service_incidents_total counter' "${TEST_DIRECTORY}/metrics/watchdog.prom" >/dev/null
if grep -E 'incident-[0-9]|market-action|secret' "${TEST_DIRECTORY}/metrics/watchdog.prom" >/dev/null; then
    printf 'Metrics exposed sensitive incident or remediation data.\n' >&2
    exit 1
fi

# validate must be read-only, and enforce must reject relative executables.
safe_true="$(realpath -e /usr/bin/true)"
cat >"${TEST_DIRECTORY}/validate.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/validate.log
  lock_file: ${TEST_DIRECTORY}/validate.lock
  state_directory: ${TEST_DIRECTORY}/validate-state
security:
  remediation_policy:
    mode: enforce
    allowed_commands:
      - command: [${safe_true}]
metrics:
  enabled: true
  textfile_directory: ${TEST_DIRECTORY}/dry-metrics
  filename: watchdog.prom
  prefix: watchdog
hooks:
  on_failure:
    - command: [/usr/bin/touch, ${TEST_DIRECTORY}/dry-hook]
services:
  - name: offline
    check: {type: http, url: 'http://127.0.0.1:${port}/missing', attempts: 1}
    actions:
      commands:
        - command: [${safe_true}]
EOF
requests_before="$(wc -l <"${TEST_DIRECTORY}/requests")"
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/validate.yaml" >"${TEST_DIRECTORY}/validate.out"
grep -F 'Configuration valid:' "${TEST_DIRECTORY}/validate.out" >/dev/null
[[ "$(wc -l <"${TEST_DIRECTORY}/requests")" == "$requests_before" ]]
[[ ! -e "${TEST_DIRECTORY}/validate.log" && ! -e "${TEST_DIRECTORY}/validate-state" && ! -e "${TEST_DIRECTORY}/validate.lock" ]]

code=0
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/validate.yaml" --dry-run >/dev/null 2>&1 || code=$?
[[ "$code" == 1 ]]
[[ ! -e "${TEST_DIRECTORY}/validate-state" ]]
[[ ! -e "${TEST_DIRECTORY}/dry-hook" ]]
[[ ! -e "${TEST_DIRECTORY}/dry-metrics" ]]
grep -F 'result=would-run reason=dry-run' "${TEST_DIRECTORY}/validate.log" >/dev/null
grep -F "action=remediation-command index=0 result=would-run command=${safe_true}" "${TEST_DIRECTORY}/validate.log" >/dev/null
grep -F 'action=failure-command index=0 result=would-run' "${TEST_DIRECTORY}/validate.log" >/dev/null
yq -i '.services[0].actions.commands[0].command = ["true"]' "${TEST_DIRECTORY}/validate.yaml"
code=0
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/validate.yaml" >"${TEST_DIRECTORY}/invalid.out" 2>&1 || code=$?
[[ "$code" == 2 ]]
grep -F '.services[0].actions.commands[0].command' "${TEST_DIRECTORY}/invalid.out" >/dev/null
for forbidden_executable in "${TEST_DIRECTORY}/restore-live" "${TEST_DIRECTORY}/true-link" "$(realpath -e /usr/bin/bash)"; do
    [[ "$forbidden_executable" != "${TEST_DIRECTORY}/true-link" ]] || ln -s "$safe_true" "$forbidden_executable"
    TEST_EXECUTABLE="$forbidden_executable" yq -i \
        '.security.remediation_policy.allowed_commands[0].command = [strenv(TEST_EXECUTABLE)] | .services[0].actions.commands[0].command = [strenv(TEST_EXECUTABLE)]' \
        "${TEST_DIRECTORY}/validate.yaml"
    code=0
    bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/validate.yaml" >"${TEST_DIRECTORY}/invalid.out" 2>&1 || code=$?
    [[ "$code" == 2 ]]
    grep -F 'security.remediation_policy.allowed_commands[0].command' "${TEST_DIRECTORY}/invalid.out" >/dev/null
done

cat >"${TEST_DIRECTORY}/cycle.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/cycle.log
  lock_file: ${TEST_DIRECTORY}/cycle.lock
  state_directory: ${TEST_DIRECTORY}/cycle-state
services:
  - name: first
    check: {type: command, commands: [{command: [/usr/bin/true]}]}
    depends_on: [{name: second}]
  - name: second
    check: {type: command, commands: [{command: [/usr/bin/true]}]}
    depends_on: [{name: first}]
EOF
code=0
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/cycle.yaml" >"${TEST_DIRECTORY}/cycle.out" 2>&1 || code=$?
[[ "$code" == 2 ]]
grep -F 'reason=circular_dependency' "${TEST_DIRECTORY}/cycle.out" >/dev/null
[[ ! -e "${TEST_DIRECTORY}/cycle-state" ]]
yq -i '.services[1].depends_on[0].name = "second"' "${TEST_DIRECTORY}/cycle.yaml"
code=0
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/cycle.yaml" >"${TEST_DIRECTORY}/cycle.out" 2>&1 || code=$?
[[ "$code" == 2 ]]
grep -F 'reason=self_dependency' "${TEST_DIRECTORY}/cycle.out" >/dev/null

cat >"${TEST_DIRECTORY}/policy-hooks.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/policy-hooks.log
  lock_file: ${TEST_DIRECTORY}/policy-hooks.lock
  state_directory: ${TEST_DIRECTORY}/policy-hooks-state
  default_attempts: 1
  default_retry_delay: 0
security:
  remediation_policy:
    mode: enforce
    allowed_commands:
      - command: [${safe_true}]
services:
  - name: hook-boundary
    check: {type: command, commands: [{command: [/usr/bin/false]}]}
    actions:
      cooldown: 0
      commands:
        - command: [${safe_true}]
    escalation:
      enabled: true
      after_consecutive_unavailable: 1
      notify: false
      hooks:
        on_escalation:
          - command: [/usr/bin/touch, ${TEST_DIRECTORY}/escalation-hook]
EOF
code=0
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/policy-hooks.yaml" >/dev/null 2>&1 || code=$?
[[ "$code" == 1 && -e "${TEST_DIRECTORY}/escalation-hook" ]]

# A second one-shot run cannot reach remediation while the first owns flock.
cat >"${TEST_DIRECTORY}/hold-action" <<EOF
#!/usr/bin/env bash
printf 'attempt\n' >>"${TEST_DIRECTORY}/attempts"
while [[ ! -e "${TEST_DIRECTORY}/release" ]]; do /usr/bin/sleep 0.1; done
EOF
chmod +x "${TEST_DIRECTORY}/hold-action"
cat >"${TEST_DIRECTORY}/singleton.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/singleton.log
  lock_file: ${TEST_DIRECTORY}/singleton.lock
  state_directory: ${TEST_DIRECTORY}/singleton-state
  default_attempts: 1
  default_retry_delay: 0
services:
  - name: singleton
    check: {type: command, commands: [{command: [/usr/bin/false]}]}
    actions:
      cooldown: 0
      commands:
        - command: [${TEST_DIRECTORY}/hold-action]
EOF
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/singleton.yaml" >/dev/null 2>&1 &
FIRST_PID=$!
for ((attempt = 0; attempt < 200; attempt++)); do
    [[ ! -e "${TEST_DIRECTORY}/attempts" ]] || break
    sleep 0.1
done
[[ -e "${TEST_DIRECTORY}/attempts" ]]
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/singleton.yaml" >/dev/null 2>&1
grep -F 'result=already-running' "${TEST_DIRECTORY}/singleton.log" >/dev/null
[[ "$(wc -l <"${TEST_DIRECTORY}/attempts")" == 1 ]]
touch "${TEST_DIRECTORY}/release"
wait "$FIRST_PID" || [[ "$?" == 1 ]]
FIRST_PID=""

# A signal releases the lock after the active action exits; a new run can proceed.
rm "${TEST_DIRECTORY}/release"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/singleton.yaml" >/dev/null 2>&1 &
FIRST_PID=$!
for ((attempt = 0; attempt < 200; attempt++)); do
    [[ ! -e "${TEST_DIRECTORY}/attempts" ]] && continue
    [[ "$(wc -l <"${TEST_DIRECTORY}/attempts")" -lt 2 ]] || break
    sleep 0.1
done
[[ "$(wc -l <"${TEST_DIRECTORY}/attempts")" == 2 ]]
kill -TERM "$FIRST_PID"
touch "${TEST_DIRECTORY}/release"
code=0
wait "$FIRST_PID" || code=$?
[[ "$code" == 2 ]]
FIRST_PID=""
code=0
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/singleton.yaml" >/dev/null 2>&1 || code=$?
[[ "$code" == 1 ]]
[[ "$(wc -l <"${TEST_DIRECTORY}/attempts")" == 3 ]]

cat >"${TEST_DIRECTORY}/timeout.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/timeout.log
  lock_file: ${TEST_DIRECTORY}/timeout.lock
  state_directory: ${TEST_DIRECTORY}/timeout-state
  default_attempts: 1
  default_retry_delay: 0
services:
  - name: bounded
    check: {type: command, commands: [{command: [/usr/bin/false]}]}
    actions:
      cooldown: 0
      commands:
        - command: [/usr/bin/sleep, '5']
          timeout: 1
EOF
for attempt in 1 2; do
    code=0
    bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/timeout.yaml" >/dev/null 2>&1 || code=$?
    [[ "$code" == 1 ]]
done
[[ "$(<"${TEST_DIRECTORY}/timeout-state/bounded.remediations-total")" == 2 ]]
grep -F 'result=remediation-command-failed index=0 exit=124' "${TEST_DIRECTORY}/timeout.log" >/dev/null

printf 'Health, policy and singleton tests passed.\n'
