#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

for command_name in bash yq curl flock timeout date mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

WATCHDOG_REAL_YQ="$(command -v yq)"
export WATCHDOG_REAL_YQ
export WATCHDOG_YQ_CALLS="${TEST_DIRECTORY}/yq-calls.log"
mkdir -p "${TEST_DIRECTORY}/bin"
cat >"${TEST_DIRECTORY}/bin/yq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${WATCHDOG_YQ_CALLS}"
exec "${WATCHDOG_REAL_YQ}" "$@"
EOF
chmod +x "${TEST_DIRECTORY}/bin/yq"

cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_timeout: 5
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 5
  default_action_cooldown: 0

parallel:
  enabled: false
  max_jobs: 2

templates:
  http-default:
    check:
      type: http
      url: http://127.0.0.1:1/health
      timeout: 5
      attempts: 1

services:
  - name: cache-template
    template: http-default
EOF

PATH="${TEST_DIRECTORY}/bin:${PATH}" bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/config.yaml" \
    >"${TEST_DIRECTORY}/validate.out"
grep -F 'Configuration valid:' "${TEST_DIRECTORY}/validate.out" >/dev/null
grep -F 'join("/")' "${WATCHDOG_YQ_CALLS}" >/dev/null

yq_invocations="$(wc -l <"${WATCHDOG_YQ_CALLS}")"
(( yq_invocations <= 20 )) || {
    printf 'Configuration cache used too many yq invocations: %s\n' "$yq_invocations" >&2
    exit 1
}

printf 'YAML configuration cache test passed.\n'
