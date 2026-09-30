#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly VERSION_FILE="${PROJECT_DIR}/VERSION"
readonly PREFLIGHT_SCRIPT="${PROJECT_DIR}/scripts/release-preflight.sh"

IFS= read -r expected_version <"$VERSION_FILE" || true
expected_version="${expected_version%$'\r'}"

bash "$PREFLIGHT_SCRIPT" "v${expected_version}"

mismatch_output="$(mktemp)"
trap 'rm -f -- "$mismatch_output"' EXIT
if bash "$PREFLIGHT_SCRIPT" v999.999.999 >"$mismatch_output" 2>&1; then
    printf 'Expected release preflight to reject a mismatched tag.\n' >&2
    exit 1
fi
grep -F 'Release tag mismatch:' "$mismatch_output" >/dev/null

printf 'Version metadata test passed for v%s.\n' "$expected_version"
