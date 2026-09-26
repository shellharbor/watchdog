#!/usr/bin/env bash
set -euo pipefail

config_input="${1:-config.yaml}"
workspace="${GITHUB_WORKSPACE:-/github/workspace}"

workspace="$(realpath -e -- "$workspace")" || {
    printf '%s\n' 'Watchdog Action: GITHUB_WORKSPACE is unavailable.' >&2
    exit 2
}

if [[ "$config_input" == /* ]]; then
    config_path="$config_input"
else
    config_path="${workspace}/${config_input}"
fi

config_path="$(realpath -e -- "$config_path")" || {
    printf 'Watchdog Action: configuration file not found: %s\n' "$config_input" >&2
    exit 2
}

case "$config_path" in
    "${workspace}"/*) ;;
    *)
        printf '%s\n' 'Watchdog Action: configuration file must be inside GITHUB_WORKSPACE.' >&2
        exit 2
        ;;
esac

exec /opt/watchdog/service-watchdog.sh validate -c "$config_path"
