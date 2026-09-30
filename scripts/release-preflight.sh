#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly VERSION_FILE="${PROJECT_DIR}/VERSION"
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"

usage() {
    printf 'Usage: %s [vX.Y.Z]\n' "${0##*/}" >&2
}

if (( $# > 1 )); then
    usage
    exit 2
fi

[[ -r "$VERSION_FILE" ]] || {
    printf 'Missing VERSION file: %s\n' "$VERSION_FILE" >&2
    exit 2
}

IFS= read -r version <"$VERSION_FILE" || true
version="${version%$'\r'}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'VERSION must contain a semantic version, found: %s\n' "$version" >&2
    exit 1
}

release_tag="${1:-v${version}}"
[[ "$release_tag" == "v${version}" ]] || {
    printf 'Release tag mismatch: VERSION is %s, expected v%s, received %s\n' \
        "$version" "$version" "$release_tag" >&2
    exit 1
}

cd -- "$PROJECT_DIR"
bash ./scripts/build-watchdog.sh --check

actual_version="$(bash "$WATCHDOG_SCRIPT" --version)"
[[ "$actual_version" == "service-watchdog.sh ${version}" ]] || {
    printf 'CLI version mismatch: expected %s, found %s\n' \
        "service-watchdog.sh ${version}" "$actual_version" >&2
    exit 1
}

grep -F "/refs/tags/v${version}.zip" README.md >/dev/null || {
    printf 'README.md must reference the v%s source archive.\n' "$version" >&2
    exit 1
}
grep -F "watchdog-${version}" README.md >/dev/null || {
    printf 'README.md must reference the watchdog-%s extracted directory.\n' "$version" >&2
    exit 1
}
grep -F "## [${version}]" CHANGELOG.md >/dev/null || {
    printf 'CHANGELOG.md must contain a ## [%s] release heading.\n' "$version" >&2
    exit 1
}

expected_install_line="\"\${SOURCE_DIR}/VERSION\" \"\${INSTALL_DIR}/VERSION\""
grep -F "$expected_install_line" install.sh >/dev/null || {
    printf 'install.sh must install VERSION beside service-watchdog.sh.\n' >&2
    exit 1
}

printf 'Release preflight passed for %s.\n' "$release_tag"
