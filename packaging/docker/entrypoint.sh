#!/usr/bin/env bash
set -euo pipefail

readonly WATCHDOG_BINARY=/opt/watchdog/service-watchdog.sh
readonly DEFAULT_CONFIG=/etc/watchdog/config.yaml

config_path="${WATCHDOG_CONFIG:-$DEFAULT_CONFIG}"

if [[ ! -r "$config_path" ]]; then
    printf 'Watchdog container: configuration file is not readable: %s\n' "$config_path" >&2
    exit 2
fi

case "${1:-}" in
    healthcheck)
        exec "$WATCHDOG_BINARY" validate -c "$config_path"
        ;;
    validate|status|notify-test)
        command_mode="$1"
        shift
        exec "$WATCHDOG_BINARY" "$command_mode" -c "$config_path" "$@"
        ;;
    "")
        exec "$WATCHDOG_BINARY" -c "$config_path"
        ;;
    *)
        exec "$WATCHDOG_BINARY" "$@" -c "$config_path"
        ;;
esac
