#!/usr/bin/env bash
set -euo pipefail

readonly WATCHDOG_BINARY=/opt/watchdog/service-watchdog.sh
readonly DEFAULT_CONFIG=/etc/watchdog/config.yaml

watchdog_pid=''

signal_watchdog_descendants() {
    local parent_pid="$1" signal_name="$2"
    local proc_path child_pid stat_line stat_fields child_parent

    # A check may be wrapped by GNU timeout, which creates its own process
    # group. Walk only Watchdog's descendants through procfs so SIGTERM reaches
    # the active check as well as the monitor that owns it.
    for proc_path in /proc/[0-9]*; do
        child_pid="${proc_path##*/}"
        [[ "$child_pid" == "$parent_pid" && -r "${proc_path}/stat" ]] && continue
        [[ -r "${proc_path}/stat" ]] || continue
        stat_line="$(<"${proc_path}/stat")" || continue
        stat_fields="${stat_line##*) }"
        read -r _ child_parent _ <<<"$stat_fields"
        [[ "$child_parent" == "$parent_pid" ]] || continue
        signal_watchdog_descendants "$child_pid" "$signal_name"
        kill -s "$signal_name" "$child_pid" 2>/dev/null || true
    done
}

forward_watchdog_signal() {
    local signal_name="$1" exit_status

    trap - HUP INT TERM
    # The one-shot monitor can be waiting on a foreground check command. End
    # that command tree first, then signal Watchdog so its own trap can finish
    # cleanup with the documented exit status.
    signal_watchdog_descendants "$watchdog_pid" "$signal_name"
    kill -s "$signal_name" "$watchdog_pid" 2>/dev/null || true
    if wait "$watchdog_pid"; then
        exit_status=0
    else
        exit_status=$?
    fi
    exit "$exit_status"
}

run_watchdog() {
    local exit_status

    "$@" &
    watchdog_pid=$!
    trap 'forward_watchdog_signal HUP' HUP
    trap 'forward_watchdog_signal INT' INT
    trap 'forward_watchdog_signal TERM' TERM
    if wait "$watchdog_pid"; then
        exit_status=0
    else
        exit_status=$?
    fi
    trap - HUP INT TERM
    return "$exit_status"
}

config_path="${WATCHDOG_CONFIG:-$DEFAULT_CONFIG}"

if [[ ! -r "$config_path" ]]; then
    printf 'Watchdog container: configuration file is not readable: %s\n' "$config_path" >&2
    exit 2
fi

case "${1:-}" in
    healthcheck)
        run_watchdog "$WATCHDOG_BINARY" validate -c "$config_path"
        ;;
    validate|status|notify-test)
        command_mode="$1"
        shift
        run_watchdog "$WATCHDOG_BINARY" "$command_mode" -c "$config_path" "$@"
        ;;
    "")
        run_watchdog "$WATCHDOG_BINARY" -c "$config_path"
        ;;
    *)
        run_watchdog "$WATCHDOG_BINARY" "$@" -c "$config_path"
        ;;
esac
