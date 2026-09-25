#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"
SERVER_PID=""
cleanup() {
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
run_watchdog() {
    local result=0
    bash "$WATCHDOG_SCRIPT" -c "$1" >"${TEST_DIRECTORY}/stdout" 2>"${TEST_DIRECTORY}/stderr" || result=$?
    [[ "$result" == "$2" ]] || { printf 'Unexpected exit %s (wanted %s)\n' "$result" "$2" >&2; /usr/bin/cat "${TEST_DIRECTORY}/stderr" >&2; exit 1; }
}

set_clock 1000
cat >"${TEST_DIRECTORY}/escalation-action" <<EOF
#!/usr/bin/env bash
printf 'action\n' >>"${TEST_DIRECTORY}/escalation-actions"
EOF
chmod +x "${TEST_DIRECTORY}/escalation-action"
cat >"${TEST_DIRECTORY}/flapping.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/flapping.log
  lock_file: ${TEST_DIRECTORY}/flapping.lock
  state_directory: ${TEST_DIRECTORY}/flapping-state
  default_attempts: 1
  default_retry_delay: 0
services:
  - name: unstable
    check:
      type: command
      commands:
        - command: [/usr/bin/test, -f, ${TEST_DIRECTORY}/up]
    actions:
      cooldown: 0
      commands:
        - command: [/usr/bin/true]
    flapping:
      enabled: true
      window_seconds: 60
      threshold: 3
      hold_seconds: 10
      recovery_seconds: 5
      notify: false
    escalation:
      enabled: true
      after_consecutive_unavailable: 1
      notify: false
      actions:
        commands:
          - command: [${TEST_DIRECTORY}/escalation-action]
EOF
touch "${TEST_DIRECTORY}/up"
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 0
rm "${TEST_DIRECTORY}/up"
set_clock 1001
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/flapping-state/unstable.remediations-total")" == 1 ]]
[[ "$(wc -l <"${TEST_DIRECTORY}/escalation-actions")" == 1 ]]
touch "${TEST_DIRECTORY}/up"
set_clock 1002
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 0
[[ "$(<"${TEST_DIRECTORY}/flapping-state/unstable.flapping-active")" == true ]]
rm "${TEST_DIRECTORY}/up"
set_clock 1003
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/flapping-state/unstable.remediations-total")" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/flapping-state/unstable.blocked-flapping-total")" == 1 ]]
[[ "$(wc -l <"${TEST_DIRECTORY}/escalation-actions")" == 1 ]]
touch "${TEST_DIRECTORY}/up"
set_clock 1005
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 0
set_clock 1012
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 0
[[ "$(<"${TEST_DIRECTORY}/flapping-state/unstable.flapping-active")" == false ]]
rm "${TEST_DIRECTORY}/up"
set_clock 1013
run_watchdog "${TEST_DIRECTORY}/flapping.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/flapping-state/unstable.remediations-total")" == 2 ]]

set_clock 2000
cat >"${TEST_DIRECTORY}/backoff.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/backoff.log
  lock_file: ${TEST_DIRECTORY}/backoff.lock
  state_directory: ${TEST_DIRECTORY}/backoff-state
  default_attempts: 1
  default_retry_delay: 0
services:
  - name: backoff-service
    check:
      type: command
      commands:
        - command: [/usr/bin/test, -f, ${TEST_DIRECTORY}/backoff-up]
    actions:
      cooldown: 3
      backoff: {enabled: true, initial_delay: 2, multiplier: 2, max_delay: 5}
      commands:
        - command: [/usr/bin/true]
EOF
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.backoff-next-attempt")" == 2002 ]]
set_clock 2001
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.remediations-total")" == 1 ]]
set_clock 2003
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.backoff-next-attempt")" == 2007 ]]
set_clock 2007
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.backoff-next-attempt")" == 2012 ]]
set_clock 2012
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.backoff-next-attempt")" == 2017 ]]
touch "${TEST_DIRECTORY}/backoff-up"
set_clock 2013
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 0
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.backoff-failures")" == 0 ]]
rm "${TEST_DIRECTORY}/backoff-up"
set_clock 2014
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.remediations-total")" == 4 ]]
set_clock 2015
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.remediations-total")" == 5 ]]
set_clock 1990
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.remediations-total")" == 5 ]]
set_clock 1993
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.backoff-next-attempt")" == 1995 ]]
set_clock 1995
run_watchdog "${TEST_DIRECTORY}/backoff.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/backoff-state/backoff-service.remediations-total")" == 6 ]]
grep -F 'reason=clock-moved-backwards' "${TEST_DIRECTORY}/backoff.log" >/dev/null

cat >"${TEST_DIRECTORY}/levels.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/levels.log
  lock_file: ${TEST_DIRECTORY}/levels.lock
  state_directory: ${TEST_DIRECTORY}/levels-state
  default_attempts: 1
  default_retry_delay: 0
services:
  - name: escalation-levels
    check:
      type: command
      commands:
        - command: [/usr/bin/test, -f, ${TEST_DIRECTORY}/levels-up]
    actions:
      cooldown: 0
      commands:
        - command: [/usr/bin/true]
    escalation:
      enabled: true
      levels:
        - after_consecutive_unavailable: 2
          notify: false
        - after_duration_seconds: 6
          notify: false
          manual_intervention: true
EOF
set_clock 4000
run_watchdog "${TEST_DIRECTORY}/levels.yaml" 1
set_clock 4003
run_watchdog "${TEST_DIRECTORY}/levels.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/levels-state/escalation-levels.escalations-total")" == 1 ]]
set_clock 4006
run_watchdog "${TEST_DIRECTORY}/levels.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/levels-state/escalation-levels.escalations-total")" == 2 ]]
[[ "$(<"${TEST_DIRECTORY}/levels-state/escalation-levels.manual-block")" == true ]]
set_clock 4007
run_watchdog "${TEST_DIRECTORY}/levels.yaml" 1
[[ "$(<"${TEST_DIRECTORY}/levels-state/escalation-levels.escalations-total")" == 2 ]]
[[ "$(<"${TEST_DIRECTORY}/levels-state/escalation-levels.remediations-total")" == 3 ]]
touch "${TEST_DIRECTORY}/levels-up"
set_clock 4008
run_watchdog "${TEST_DIRECTORY}/levels.yaml" 0
[[ ! -e "${TEST_DIRECTORY}/levels-state/escalation-levels.manual-block" ]]

printf 'Reliability tests passed.\n'
