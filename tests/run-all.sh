#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR

# Keep this explicit order as the authoritative test inventory. The coverage
# check below fails if a test is added to tests/ without being registered here.
readonly TEST_SCRIPTS=(
    circuit-breaker.sh
    conditional.sh
    dependencies.sh
    discovery.sh
    disk-space.sh
    email-notifications.sh
    escalation.sh
    federation.sh
    health-policy.sh
    history.sh
    maintenance.sh
    notify-test.sh
    parallel.sh
    prometheus.sh
    reliability.sh
    schema.sh
    security.sh
    smart-http.sh
    smoke.sh
    status-command.sh
    status-page.sh
    templates.sh
    versioning.sh
    webhooks.sh
)

declare -A registered_tests=()
for test_script in "${TEST_SCRIPTS[@]}"; do
    [[ -z "${registered_tests[$test_script]:-}" ]] || {
        printf 'Test is registered more than once: %s\n' "$test_script" >&2
        exit 2
    }
    [[ -f "${TESTS_DIR}/${test_script}" ]] || {
        printf 'Registered test is missing: %s\n' "$test_script" >&2
        exit 2
    }
    registered_tests["$test_script"]=1
done

for test_path in "${TESTS_DIR}"/*.sh; do
    test_script="${test_path##*/}"
    [[ "$test_script" == run-all.sh ]] && continue
    [[ -n "${registered_tests[$test_script]:-}" ]] || {
        printf 'Test is not registered in tests/run-all.sh: %s\n' "$test_script" >&2
        exit 2
    }
done

for test_script in "${TEST_SCRIPTS[@]}"; do
    printf '\n==> %s\n' "$test_script"
    bash "${TESTS_DIR}/${test_script}"
done

printf '\nAll %s regression tests passed.\n' "${#TEST_SCRIPTS[@]}"
