#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
readonly VERSION_FILE="${PROJECT_DIR}/VERSION"

[[ -r "$VERSION_FILE" ]] || {
    printf 'Missing VERSION file: %s\n' "$VERSION_FILE" >&2
    exit 2
}

IFS= read -r expected_version <"$VERSION_FILE" || true
expected_version="${expected_version%$'\r'}"
[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'VERSION must contain a semantic version, found: %s\n' "$expected_version" >&2
    exit 1
}

actual_version="$(bash "$WATCHDOG_SCRIPT" --version)"
[[ "$actual_version" == "service-watchdog.sh ${expected_version}" ]] || {
    printf 'CLI version mismatch: expected %s, found %s\n' \
        "service-watchdog.sh ${expected_version}" "$actual_version" >&2
    exit 1
}

grep -F "/refs/tags/v${expected_version}.zip" "${PROJECT_DIR}/README.md" >/dev/null
grep -F "watchdog-${expected_version}" "${PROJECT_DIR}/README.md" >/dev/null
grep -F "## [${expected_version}]" "${PROJECT_DIR}/CHANGELOG.md" >/dev/null
expected_install_line="\"\${SOURCE_DIR}/VERSION\" \"\${INSTALL_DIR}/VERSION\""
grep -F "$expected_install_line" "${PROJECT_DIR}/install.sh" >/dev/null

printf 'Version metadata test passed for v%s.\n' "$expected_version"
