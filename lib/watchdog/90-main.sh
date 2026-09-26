main() {
    local option argument yq_version service_count index matched=0 name source_config
    local -a parsed_arguments=()

    case "${1:-}" in
        validate) VALIDATE_ONLY=1; COMMAND_MODE=validate; shift ;;
        --report|--trend)
            HISTORY_COMMAND="$1"; COMMAND_MODE=history; VALIDATE_ONLY=1; shift
            (( $# > 0 )) || die "${HISTORY_COMMAND} requires a value."
            HISTORY_ARGUMENT="$1"; shift
            if [[ "$HISTORY_COMMAND" == --report ]]; then
                case "$HISTORY_ARGUMENT" in daily|weekly|monthly) ;; *) die 'Report period must be daily, weekly, or monthly.' ;; esac
            fi
            while (( $# > 0 )); do
                case "$1" in
                    -c|--config) (( $# >= 2 )) || die 'Option -c requires a value.'; CONFIG_FILE="$2"; shift 2 ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unexpected argument: $1" ;;
                esac
            done
            set --
            ;;
        notify-test|status)
            COMMAND_MODE="$1"; VALIDATE_ONLY=1
            [[ "$COMMAND_MODE" != notify-test ]] || NOTIFY_TEST_MODE=1
            shift
            while (( $# > 0 )); do
                case "$1" in
                    -c) (( $# >= 2 )) || die 'Option -c requires a value.'; CONFIG_FILE="$2"; shift 2 ;;
                    -s) (( $# >= 2 )) || die 'Option -s requires a value.'; ONLY_SERVICE="$2"; shift 2 ;;
                    --channel)
                        [[ "$COMMAND_MODE" == notify-test ]] || die 'Option --channel is only valid for notify-test.'
                        (( $# >= 2 )) || die 'Option --channel requires a value.'
                        NOTIFY_TEST_CHANNEL="$2"; shift 2 ;;
                    --event)
                        [[ "$COMMAND_MODE" == notify-test ]] || die 'Option --event is only valid for notify-test.'
                        (( $# >= 2 )) || die 'Option --event requires a value.'
                        NOTIFY_TEST_EVENT="$2"; shift 2 ;;
                    --json) [[ "$COMMAND_MODE" == status ]] || die 'Option --json is only valid for status.'; STATUS_JSON=1; shift ;;
                    --all) [[ "$COMMAND_MODE" == status ]] || die 'Option --all is only valid for status.'; STATUS_ALL=1; shift ;;
                    -h|--help) usage; exit 0 ;;
                    --dry-run|-n) die 'Subcommands do not accept --dry-run; no checks or remediation run.' ;;
                    *) die "Unexpected argument: $1" ;;
                esac
            done
            if [[ "$COMMAND_MODE" == notify-test ]]; then
                case "$NOTIFY_TEST_CHANNEL" in email|telegram|discord|slack|ntfy|pagerduty|opsgenie|all) ;; *) die "Invalid notify-test channel: ${NOTIFY_TEST_CHANNEL}" ;; esac
                case "$NOTIFY_TEST_EVENT" in failure|recovery|escalation) ;; *) die "Invalid notify-test event: ${NOTIFY_TEST_EVENT}" ;; esac
            fi
            set --
            ;;
    esac
    for argument in "$@"; do
        if [[ "$argument" == --dry-run ]]; then
            DRY_RUN=1
        else
            parsed_arguments+=("$argument")
        fi
    done
    set -- "${parsed_arguments[@]}"
    if [[ "${1:-}" == "--version" ]]; then
        printf '%s %s\n' "$SCRIPT_NAME" "$WATCHDOG_VERSION"
        exit 0
    fi

    while getopts ':c:s:nhV' option; do
        case "$option" in
            c) CONFIG_FILE="$OPTARG" ;;
            s) ONLY_SERVICE="$OPTARG" ;;
            n) DRY_RUN=1 ;;
            V) printf '%s %s\n' "$SCRIPT_NAME" "$WATCHDOG_VERSION"; exit 0 ;;
            h) usage; exit 0 ;;
            :) bootstrap_log CRITICAL "Option -${OPTARG} requires a value."; exit 2 ;;
            \?) bootstrap_log CRITICAL "Unknown option: -${OPTARG}"; usage >&2; exit 2 ;;
        esac
    done
    shift "$((OPTIND - 1))"
    (( $# == 0 )) || die "Unexpected argument: $1"

    [[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: ${CONFIG_FILE}"
    source_config="$CONFIG_FILE"
    for name in bash base64 curl yq flock timeout date dirname mktemp tail tr mv env awk df hostname find; do
        require_command "$name"
    done
    yq_version="$(yq --version 2>/dev/null)" || die "Cannot determine yq version."
    [[ "$yq_version" =~ version[[:space:]]+v?4\. ]] || die "Mike Farah yq v4 is required: ${yq_version}"

    yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1 || die "YAML is syntactically invalid: ${CONFIG_FILE}"
    load_yaml_cache
    load_runtime_settings
    validate_templates
    if [[ "$COMMAND_MODE" == status || "$COMMAND_MODE" == history ]]; then expand_templates_readonly; else expand_templates; fi
    load_yaml_cache
    validate_configuration
    history_validate_config
    if [[ "$COMMAND_MODE" == status ]]; then status_run; exit $?; fi
    if [[ "$COMMAND_MODE" == history ]]; then
        if [[ "$HISTORY_COMMAND" == --report ]]; then generate_report "$HISTORY_ARGUMENT"; else generate_trend "$HISTORY_ARGUMENT"; fi
        exit $?
    fi
    if [[ "$COMMAND_MODE" == notify-test ]]; then notify_test_run; exit $?; fi
    if (( VALIDATE_ONLY == 1 )); then
        if [[ "$(yaml_read '.security.remediation_policy.mode // "legacy"')" == legacy ]]; then
            bootstrap_log WARN 'security.remediation_policy.mode=legacy; migrate actions to an enforced exact-command allowlist.'
        fi
        printf 'Configuration valid: %s\n' "$source_config"
        exit 0
    fi
    configure_runtime
    configure_parallel
    configure_email
    configure_metrics
    configure_status_page
    configure_federation
    if (( PARALLEL_ENABLED == 1 )); then
        TEMP_DIRECTORY="$(mktemp -d "${PARALLEL_TEMP_BASE%/}/watchdog.XXXXXX")" || die "Cannot create parallel temporary directory."
    else
        TEMP_DIRECTORY="$(mktemp -d)" || die "Cannot create temporary directory."
    fi
    exec 9>"$LOCK_FILE" || die "Cannot open lock file: ${LOCK_FILE}"
    if ! flock --nonblock 9; then
        log WARN "action=lock result=already-running"
        exit 0
    fi

    log_template_expansions
    log INFO "action=watchdog-start config=${CONFIG_FILE} dry_run=${DRY_RUN}"
    if [[ "$(yaml_read '.security.remediation_policy.mode // "legacy"')" == legacy ]]; then
        log WARN 'security.remediation_policy.mode=legacy; migrate actions to an enforced exact-command allowlist.'
    fi
    if (( FEDERATION_HUB_ENABLED == 1 )); then
        federation_hub_process_reports
        if [[ "$FEDERATION_HUB_OVERALL_STATUS" == operational ]]; then
            log INFO "action=watchdog-finish mode=federation-hub exit=0 overall=operational"
            exit 0
        fi
        log WARN "action=watchdog-finish mode=federation-hub exit=1 overall=${FEDERATION_HUB_OVERALL_STATUS}"
        exit 1
    fi
    service_count="$(yaml_read '.services | length')"
    if [[ -n "$ONLY_SERVICE" ]]; then
        for ((index = 0; index < service_count; index++)); do
            name="$(yaml_read ".services[$index].name")"
            [[ "$name" == "$ONLY_SERVICE" ]] && matched=1
        done
        (( matched == 1 )) || die "Service not found: ${ONLY_SERVICE}"
    fi

    RESOLVED_STATE=()
    CONDITION_SKIPPED=()
    CONDITION_EVALUATED=()
    FEDERATION_STATE_CHANGED=0
    if (( PARALLEL_ENABLED == 1 )); then
        local max_level=0 level
        for name in "${SERVICE_ORDER[@]}"; do
            (( max_level < SERVICE_LEVEL[$name] )) && max_level="${SERVICE_LEVEL[$name]}"
        done
        for ((level = 0; level <= max_level; level++)); do
            process_parallel_level "$level"
        done
    else
        for name in "${SERVICE_ORDER[@]}"; do
            if [[ -n "$ONLY_SERVICE" && "$name" != "$ONLY_SERVICE" ]] && ! service_is_required_for "$ONLY_SERVICE" "$name"; then
                continue
            fi
            index="${SERVICE_INDEX[$name]}"
            process_service "$index"
            RESOLVED_STATE["$name"]="$PROCESS_RESULT"
            history_capture_service "$name"
        done
    fi

    write_prometheus_metrics
    write_history
    generate_status_page
    federation_agent_send_report

    if (( UNHEALTHY_FOUND == 1 || ACTION_ATTEMPTED == 1 )); then
        log WARN "action=watchdog-finish exit=1 unhealthy=${UNHEALTHY_FOUND} remediation=${ACTION_ATTEMPTED}"
        exit 1
    fi
    log INFO "action=watchdog-finish exit=0 unhealthy=0 remediation=0"
    exit 0
}

main "$@"
