action_is_due() {
    local index="$1" service_name="$2"
    local cooldown file last_action="" now
    cooldown="$(yaml_read ".services[$index].actions.cooldown // ${DEFAULT_ACTION_COOLDOWN}")"
    (( cooldown == 0 )) && return 0
    file="${STATE_DIRECTORY}/${service_name}.last-action"
    if [[ -r "$file" ]]; then
        IFS= read -r last_action <"$file" || true
    fi
    [[ "$last_action" =~ ^[0-9]+$ ]] || return 0
    now="$(date '+%s')"
    if (( now < 10#$last_action )); then
        (( DRY_RUN == 1 )) || write_service_marker_number "$service_name" last-action "$now"
        log WARN "service=${service_name} action=remediation result=skipped reason=clock-moved-backwards cooldown=${cooldown}"
        return 1
    fi
    (( now - last_action >= cooldown ))
}

record_action_attempt() {
    local service_name="$1"
    local file temporary
    file="${STATE_DIRECTORY}/${service_name}.last-action"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$(date '+%s')" >"$temporary" || die "Cannot write action state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update action state: ${file}"
    increment_service_marker_number "$service_name" remediations-total
    incident_update "$service_name" "$(read_state "$service_name")" attempt pending
}

maintenance_marker_file() {
    local service_name="$1" marker="$2"
    printf '%s/%s.%s' "$STATE_DIRECTORY" "$service_name" "$marker"
}

read_service_marker_number() {
    local service_name="$1" marker="$2" default_value="$3" file value=""
    file="$(maintenance_marker_file "$service_name" "$marker")"
    if [[ -r "$file" ]]; then
        IFS= read -r value <"$file" || true
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || value="$default_value"
    printf '%s' "$value"
}

write_service_marker_number() {
    local service_name="$1" marker="$2" value="$3" file temporary
    file="$(maintenance_marker_file "$service_name" "$marker")"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$value" >"$temporary" || die "Cannot write service state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update service state: ${file}"
}

read_service_marker_string() {
    local service_name="$1" marker="$2" default_value="$3" file value=""
    file="$(maintenance_marker_file "$service_name" "$marker")"
    if [[ -r "$file" ]]; then
        IFS= read -r value <"$file" || true
    fi
    [[ -n "$value" ]] || value="$default_value"
    printf '%s' "$value"
}

write_service_marker_string() {
    local service_name="$1" marker="$2" value="$3" file temporary
    file="$(maintenance_marker_file "$service_name" "$marker")"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$value" >"$temporary" || die "Cannot write service state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update service state: ${file}"
}

flapping_is_active() {
    [[ "$(read_service_marker_string "$1" flapping-active false)" == true ]]
}

flapping_record_transition() {
    local index="$1" service_name="$2" now window threshold saved timestamp count
    local -a previous=() recent=()
    local IFS=' '
    [[ "$(yaml_read ".services[$index].flapping.enabled // false")" == true ]] || return 0
    (( DRY_RUN == 0 )) || { log INFO "service=${service_name} flapping=would-record-transition"; return 0; }
    now="$(date '+%s')"
    window="$(yaml_read ".services[$index].flapping.window_seconds")"
    threshold="$(yaml_read ".services[$index].flapping.threshold")"
    saved="$(read_service_marker_string "$service_name" flapping-transitions "")"
    IFS=' ' read -r -a previous <<<"$saved"
    for timestamp in "${previous[@]}"; do
        [[ "$timestamp" =~ ^[0-9]+$ ]] || continue
        (( now >= timestamp && now - timestamp <= 10#$window )) && recent+=("$timestamp")
    done
    recent+=("$now")
    while (( ${#recent[@]} > 10#$threshold )); do recent=("${recent[@]:1}"); done
    write_service_marker_string "$service_name" flapping-transitions "${recent[*]}"
    count="${#recent[@]}"
    if (( count >= 10#$threshold )) && ! flapping_is_active "$service_name"; then
        write_service_marker_string "$service_name" flapping-active true
        write_service_marker_number "$service_name" flapping-opened "$now"
        write_service_marker_number "$service_name" flapping-stable-since 0
        increment_service_marker_number "$service_name" flapping-events-total
        log WARN "service=${service_name} event=flapping transitions=${count} window_seconds=${window} action=remediation-blocked"
        if (( MAINTENANCE_ACTIVE == 0 )) && [[ "$(yaml_read_true_default ".services[$index].flapping.notify")" == true ]]; then
            send_email_notification flapping || log ERROR "service=${service_name} result=flapping-email-failed"
            send_webhook_notification flapping || log ERROR "service=${service_name} result=flapping-webhook-failed"
        fi
    fi
}

flapping_record_health() {
    local index="$1" service_name="$2" healthy="$3" now stable opened hold recovery
    [[ "$(yaml_read ".services[$index].flapping.enabled // false")" == true ]] || return 0
    flapping_is_active "$service_name" || return 0
    (( DRY_RUN == 0 )) || return 0
    if [[ "$healthy" != true ]]; then
        write_service_marker_number "$service_name" flapping-stable-since 0
        return 0
    fi
    now="$(date '+%s')"
    stable="$(read_service_marker_number "$service_name" flapping-stable-since 0)"
    opened="$(read_service_marker_number "$service_name" flapping-opened 0)"
    hold="$(yaml_read ".services[$index].flapping.hold_seconds")"
    recovery="$(yaml_read ".services[$index].flapping.recovery_seconds")"
    if (( 10#$stable == 0 || now < 10#$stable )); then
        write_service_marker_number "$service_name" flapping-stable-since "$now"
        return 0
    fi
    if (( now >= 10#$opened + 10#$hold && now >= 10#$stable + 10#$recovery )); then
        write_service_marker_string "$service_name" flapping-active false
        write_service_marker_string "$service_name" flapping-transitions ""
        incident_update "$service_name" "$(read_state "$service_name")" flapping-clear
        log INFO "service=${service_name} event=flapping-recovered stable_seconds=$((now - 10#$stable)) action=remediation-unblocked"
    fi
}

backoff_is_due() {
    local index="$1" service_name="$2" now next last initial
    [[ "$(yaml_read ".services[$index].actions.backoff.enabled // false")" == true ]] || return 0
    now="$(date '+%s')"
    next="$(read_service_marker_number "$service_name" backoff-next-attempt 0)"
    last="$(read_service_marker_number "$service_name" backoff-last-failure 0)"
    if (( 10#$last > now )); then
        initial="$(yaml_read ".services[$index].actions.backoff.initial_delay")"
        (( DRY_RUN == 1 )) || { write_service_marker_number "$service_name" backoff-last-failure "$now"; write_service_marker_number "$service_name" backoff-next-attempt "$((now + 10#$initial))"; }
        log WARN "service=${service_name} action=remediation result=skipped reason=clock-moved-backwards delay=${initial}"
        return 1
    fi
    if (( now < 10#$next )); then
        log INFO "service=${service_name} action=remediation result=skipped reason=backoff remaining=$((10#$next - now))"
        return 1
    fi
    return 0
}

backoff_record_failure() {
    local index="$1" service_name="$2" failures initial multiplier maximum delay step now
    [[ "$(yaml_read ".services[$index].actions.backoff.enabled // false")" == true ]] || return 0
    (( DRY_RUN == 0 )) || return 0
    failures="$(read_service_marker_number "$service_name" backoff-failures 0)"
    failures=$((10#$failures + 1))
    initial="$(yaml_read ".services[$index].actions.backoff.initial_delay")"
    multiplier="$(yaml_read ".services[$index].actions.backoff.multiplier")"
    maximum="$(yaml_read ".services[$index].actions.backoff.max_delay")"
    delay=$((10#$initial))
    for ((step = 1; step < failures && delay < 10#$maximum; step++)); do
        if (( delay > 10#$maximum / 10#$multiplier )); then delay=$((10#$maximum)); else delay=$((delay * 10#$multiplier)); fi
    done
    now="$(date '+%s')"
    write_service_marker_number "$service_name" backoff-failures "$failures"
    write_service_marker_number "$service_name" backoff-last-failure "$now"
    write_service_marker_number "$service_name" backoff-next-attempt "$((now + delay))"
    log WARN "service=${service_name} action=remediation result=failed backoff_failures=${failures} next_delay=${delay}"
}

backoff_reset() {
    local index="$1" service_name="$2"
    [[ "$(yaml_read ".services[$index].actions.backoff.enabled // false")" == true ]] || return 0
    (( DRY_RUN == 0 )) || return 0
    write_service_marker_number "$service_name" backoff-failures 0
    write_service_marker_number "$service_name" backoff-last-failure 0
    write_service_marker_number "$service_name" backoff-next-attempt 0
}

send_circuit_breaker_notification() {
    local index="$1" service_name="$2" event="$3" notify hook_expression
    notify="$(yaml_read_true_default ".services[$index].circuit_breaker.notify")"
    if [[ "$notify" == true ]]; then
        send_email_notification "circuit_${event}" || log ERROR "service=${service_name} result=circuit-email-failed event=${event}"
        send_webhook_notification "circuit_${event}" || log ERROR "service=${service_name} result=circuit-webhook-failed event=${event}"
    fi
    hook_expression=".services[$index].circuit_breaker.hooks.on_${event}"
    run_configured_sequence "$hook_expression" "circuit-${event}" "$service_name" ||
        log ERROR "service=${service_name} result=circuit-hook-failed event=${event}"
    log WARN "service=${service_name} event=circuit_breaker_${event} notify=${notify}"
}

should_run_actions_with_circuit_breaker() {
    local index="$1" service_name="$2" circuit_state last_open open_duration now remaining
    [[ "$(yaml_read ".services[$index].circuit_breaker.enabled // false")" == true ]] || return 0
    circuit_state="$(read_service_marker_string "$service_name" circuit-state closed)"
    case "$circuit_state" in
        closed) return 0 ;;
        open)
            last_open="$(read_service_marker_number "$service_name" last-circuit-open 0)"
            open_duration="$(yaml_read ".services[$index].circuit_breaker.open_duration")"
            now="$(date '+%s')"
            if (( 10#$last_open > 0 && now - 10#$last_open >= 10#$open_duration )); then
                if (( DRY_RUN == 0 )); then
                    write_service_marker_string "$service_name" circuit-state half_open
                    write_service_marker_number "$service_name" last-half-open-attempt "$now"
                fi
                log WARN "service=${service_name} circuit_state=open action=half_open reason=open_duration_expired"
                return 0
            fi
            remaining=$((10#$open_duration - (now - 10#$last_open)))
            log INFO "service=${service_name} circuit_state=open action=skipped reason=circuit_breaker last_open=${last_open} remaining=${remaining}"
            return 1
            ;;
        half_open) return 0 ;;
        *) (( DRY_RUN == 1 )) || write_service_marker_string "$service_name" circuit-state closed; return 0 ;;
    esac
}

record_circuit_action_result() {
    local index="$1" service_name="$2" success="$3" circuit_state failures threshold now
    (( DRY_RUN == 0 )) || return 0
    [[ "$(yaml_read ".services[$index].circuit_breaker.enabled // false")" == true ]] || return 0
    circuit_state="$(read_service_marker_string "$service_name" circuit-state closed)"
    if [[ "$success" == true ]]; then
        write_service_marker_string "$service_name" circuit-state closed
        write_service_marker_number "$service_name" circuit-failure-count 0
        rm -f -- "$(maintenance_marker_file "$service_name" last-circuit-open)"
        if [[ "$circuit_state" == open || "$circuit_state" == half_open ]]; then
            log INFO "service=${service_name} circuit_state=${circuit_state} action=verify result=success next_state=closed"
            send_circuit_breaker_notification "$index" "$service_name" close
        fi
        return 0
    fi
    now="$(date '+%s')"
    if [[ "$circuit_state" == half_open ]]; then
        write_service_marker_string "$service_name" circuit-state open
        write_service_marker_number "$service_name" last-circuit-open "$now"
        log WARN "service=${service_name} circuit_state=half_open action=verify result=failed next_state=open"
        send_circuit_breaker_notification "$index" "$service_name" open
        return 0
    fi
    failures="$(read_service_marker_number "$service_name" circuit-failure-count 0)"
    failures=$((10#$failures + 1))
    write_service_marker_number "$service_name" circuit-failure-count "$failures"
    threshold="$(yaml_read ".services[$index].circuit_breaker.failure_threshold")"
    log WARN "service=${service_name} circuit_state=closed circuit_failure_count=${failures} action=remediation result=failed"
    if (( failures >= 10#$threshold )); then
        write_service_marker_string "$service_name" circuit-state open
        write_service_marker_number "$service_name" last-circuit-open "$now"
        log WARN "service=${service_name} circuit_state=closed circuit_failure_count=${failures} threshold=${threshold} action=trip reason=failure_threshold_reached"
        send_circuit_breaker_notification "$index" "$service_name" open
    fi
}

increment_service_marker_number() {
    local service_name="$1" marker="$2" current
    (( DRY_RUN == 0 )) || return 0
    current="$(read_service_marker_number "$service_name" "$marker" 0)"
    write_service_marker_number "$service_name" "$marker" "$((10#$current + 1))"
}

record_check_attempt() {
    local service_name="$1"
    (( DRY_RUN == 0 )) || return 0
    increment_service_marker_number "$service_name" checks-total
    write_service_marker_number "$service_name" last-check "$(date '+%s')"
}

record_http_timing() {
    local service_name="$1" latency_threshold=0
    [[ "$CURRENT_CHECK_TYPE" == http && "$CHECK_HTTP_TOTAL_MS" =~ ^[0-9]+$ ]] || return 0
    (( DRY_RUN == 0 )) || return 0
    [[ "$CHECK_HTTP_MAX_TOTAL_MS" =~ ^[0-9]+$ ]] && latency_threshold="$CHECK_HTTP_MAX_TOTAL_MS"
    write_service_marker_number "$service_name" http-last-total-ms "$CHECK_HTTP_TOTAL_MS"
    write_service_marker_number "$service_name" http-latency-threshold-ms "$latency_threshold"
}

record_state_transition_timestamp() {
    local service_name="$1"
    (( DRY_RUN == 0 )) || return 0
    write_service_marker_number "$service_name" last-transition "$(date '+%s')"
}

escape_prometheus_label_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

sanitize_prometheus_metric_name() {
    local value="$1"
    value="${value//[^A-Za-z0-9_:]/_}"
    [[ "$value" =~ ^[A-Za-z_:] ]] || value="_${value}"
    printf '%s' "$value"
}

prometheus_labels() {
    local service_name="$1" check_type="$2" count index key value
    printf 'service="%s",check_type="%s"' "$(escape_prometheus_label_value "$service_name")" "$(escape_prometheus_label_value "$check_type")"
    count="$(yaml_read '.metrics.static_labels // {} | length')"
    for ((index = 0; index < count; index++)); do
        key="$(yaml_read ".metrics.static_labels | to_entries[$index].key")"
        value="$(yaml_read ".metrics.static_labels | to_entries[$index].value")"
        printf ',%s="%s"' "$key" "$(escape_prometheus_label_value "$value")"
    done
}

write_prometheus_metrics() {
    local target temporary service_count index service_name check_type state state_value now
    local last_check last_transition failures checks remediations outage labels metric_prefix
    local errors remediation_success remediation_failed incidents incident_active incident_started incident_duration last_incident_duration
    local last_success escalations blocked_dependency blocked_backoff blocked_flapping flapping_active backoff_until backoff_remaining http_total_ms http_latency_threshold_ms
    (( METRICS_ENABLED == 1 )) || return 0
    if (( DRY_RUN == 1 )); then
        log INFO 'result=metrics-skipped reason=dry-run'
        return 0
    fi
    target="${METRICS_DIRECTORY}/${METRICS_FILENAME}"
    if [[ ! -d "$METRICS_DIRECTORY" ]]; then
        if ! mkdir -p -- "$METRICS_DIRECTORY" 2>/dev/null || ! chmod 0755 "$METRICS_DIRECTORY" 2>/dev/null; then
            log ERROR "result=metrics-failed file=${target} reason=directory-not-writable"
            return 0
        fi
    fi
    if [[ ! -w "$METRICS_DIRECTORY" ]]; then
        log ERROR "result=metrics-failed file=${target} reason=directory-not-writable"
        return 0
    fi
    temporary="$(mktemp "${METRICS_DIRECTORY}/.${METRICS_FILENAME}.XXXXXX" 2>/dev/null)" || {
        log ERROR "result=metrics-failed file=${target} reason=temporary-file"
        return 0
    }
    metric_prefix="$(sanitize_prometheus_metric_name "$METRICS_PREFIX")"
    now="$(date '+%s')"
    service_count="$(yaml_read '.services | length')"
    {
        printf '# HELP %s_service_state Service state (0=healthy, 1=unavailable, 2=unknown, 3=dependency_failed, 4=degraded, 5=recovering)\n' "$metric_prefix"
        printf '# TYPE %s_service_state gauge\n' "$metric_prefix"
        printf '# HELP %s_service_last_check_timestamp Unix timestamp of the last check attempt\n' "$metric_prefix"
        printf '# TYPE %s_service_last_check_timestamp gauge\n' "$metric_prefix"
        printf '# HELP %s_service_last_transition_timestamp Unix timestamp of the last state transition\n' "$metric_prefix"
        printf '# TYPE %s_service_last_transition_timestamp gauge\n' "$metric_prefix"
        printf '# HELP %s_service_consecutive_failures Total consecutive unavailable checks since last healthy state\n' "$metric_prefix"
        printf '# TYPE %s_service_consecutive_failures gauge\n' "$metric_prefix"
        printf '# HELP %s_service_checks_total Total number of check attempts performed\n' "$metric_prefix"
        printf '# TYPE %s_service_checks_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_remediations_total Total number of remediation attempts performed\n' "$metric_prefix"
        printf '# TYPE %s_service_remediations_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_current_outage_duration_seconds Duration of the current outage in seconds\n' "$metric_prefix"
        printf '# TYPE %s_service_current_outage_duration_seconds gauge\n' "$metric_prefix"
        printf '# HELP %s_service_check_errors_total Failed check attempts\n' "$metric_prefix"
        printf '# TYPE %s_service_check_errors_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_remediations_success_total Confirmed successful remediation attempts\n' "$metric_prefix"
        printf '# TYPE %s_service_remediations_success_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_remediations_failed_total Failed or unconfirmed remediation attempts\n' "$metric_prefix"
        printf '# TYPE %s_service_remediations_failed_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_incidents_total Incidents opened\n' "$metric_prefix"
        printf '# TYPE %s_service_incidents_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_current_incident_duration_seconds Duration of an active incident\n' "$metric_prefix"
        printf '# TYPE %s_service_current_incident_duration_seconds gauge\n' "$metric_prefix"
        printf '# HELP %s_service_last_incident_duration_seconds Duration of the last completed incident\n' "$metric_prefix"
        printf '# TYPE %s_service_last_incident_duration_seconds gauge\n' "$metric_prefix"
        printf '# HELP %s_service_last_success_timestamp Unix timestamp of the last successful check\n' "$metric_prefix"
        printf '# TYPE %s_service_last_success_timestamp gauge\n' "$metric_prefix"
        printf '# HELP %s_service_escalations_total Escalation events\n' "$metric_prefix"
        printf '# TYPE %s_service_escalations_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_blocked_dependency_total Checks blocked by required dependencies\n' "$metric_prefix"
        printf '# TYPE %s_service_blocked_dependency_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_blocked_backoff_total Remediation attempts blocked by backoff\n' "$metric_prefix"
        printf '# TYPE %s_service_blocked_backoff_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_blocked_flapping_total Remediation attempts blocked by flapping\n' "$metric_prefix"
        printf '# TYPE %s_service_blocked_flapping_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_flapping_active Whether flapping protection is active\n' "$metric_prefix"
        printf '# TYPE %s_service_flapping_active gauge\n' "$metric_prefix"
        printf '# HELP %s_service_backoff_remaining_seconds Time until the next permitted remediation attempt\n' "$metric_prefix"
        printf '# TYPE %s_service_backoff_remaining_seconds gauge\n' "$metric_prefix"
        printf '# HELP %s_service_http_last_total_seconds Duration of the most recent HTTP request\n' "$metric_prefix"
        printf '# TYPE %s_service_http_last_total_seconds gauge\n' "$metric_prefix"
        printf '# HELP %s_service_http_latency_slo_seconds Configured maximum HTTP request duration; zero means no SLO\n' "$metric_prefix"
        printf '# TYPE %s_service_http_latency_slo_seconds gauge\n' "$metric_prefix"
        for ((index = 0; index < service_count; index++)); do
            service_name="$(yaml_read ".services[$index].name")"
            check_type="$(service_check_type "$index")"
            labels="$(prometheus_labels "$service_name" "$check_type")"
            state="$(read_state "$service_name")"
            case "$state" in healthy) state_value=0 ;; unavailable) state_value=1 ;; dependency_failed) state_value=3 ;; degraded) state_value=4 ;; recovering) state_value=5 ;; *) state_value=2 ;; esac
            last_check="$(read_service_marker_number "$service_name" last-check 0)"
            last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
            failures="$(read_service_marker_number "$service_name" unavailable-count 0)"
            checks="$(read_service_marker_number "$service_name" checks-total 0)"
            remediations="$(read_service_marker_number "$service_name" remediations-total 0)"
            errors="$(read_service_marker_number "$service_name" check-errors-total 0)"
            remediation_success="$(read_service_marker_number "$service_name" remediations-success-total 0)"
            remediation_failed="$(read_service_marker_number "$service_name" remediations-failed-total 0)"
            incidents="$(read_service_marker_number "$service_name" incidents-total 0)"
            last_incident_duration="$(read_service_marker_number "$service_name" incident-last-duration 0)"
            last_success="$(read_service_marker_number "$service_name" last-success 0)"
            escalations="$(read_service_marker_number "$service_name" escalations-total 0)"
            blocked_dependency="$(read_service_marker_number "$service_name" blocked-dependency-total 0)"
            blocked_backoff="$(read_service_marker_number "$service_name" blocked-backoff-total 0)"
            blocked_flapping="$(read_service_marker_number "$service_name" blocked-flapping-total 0)"
            http_total_ms="$(read_service_marker_number "$service_name" http-last-total-ms 0)"
            http_latency_threshold_ms="$(read_service_marker_number "$service_name" http-latency-threshold-ms 0)"
            flapping_active=0; flapping_is_active "$service_name" && flapping_active=1
            backoff_until="$(read_service_marker_number "$service_name" backoff-next-attempt 0)"
            backoff_remaining=0; (( 10#$backoff_until > now )) && backoff_remaining=$((10#$backoff_until - now))
            incident_active="$(incident_read_field "$service_name" active false)"
            incident_started="$(incident_read_field "$service_name" started_at 0)"
            incident_duration=0
            if [[ "$incident_active" == true ]] && (( 10#$incident_started > 0 && now >= 10#$incident_started )); then
                incident_duration=$((now - 10#$incident_started))
            fi
            outage=0
            if [[ "$state" == unavailable ]]; then
                if (( incident_duration > 0 )); then outage="$incident_duration"
                elif (( 10#$last_transition > 0 && now >= 10#$last_transition )); then outage=$((now - 10#$last_transition)); fi
            fi
            printf '%s_service_state{%s} %s\n' "$metric_prefix" "$labels" "$state_value"
            printf '%s_service_last_check_timestamp{%s} %s\n' "$metric_prefix" "$labels" "$last_check"
            printf '%s_service_last_transition_timestamp{%s} %s\n' "$metric_prefix" "$labels" "$last_transition"
            printf '%s_service_consecutive_failures{%s} %s\n' "$metric_prefix" "$labels" "$failures"
            printf '%s_service_checks_total{%s} %s\n' "$metric_prefix" "$labels" "$checks"
            printf '%s_service_remediations_total{%s} %s\n' "$metric_prefix" "$labels" "$remediations"
            printf '%s_service_current_outage_duration_seconds{%s} %s\n' "$metric_prefix" "$labels" "$outage"
            printf '%s_service_check_errors_total{%s} %s\n' "$metric_prefix" "$labels" "$errors"
            printf '%s_service_remediations_success_total{%s} %s\n' "$metric_prefix" "$labels" "$remediation_success"
            printf '%s_service_remediations_failed_total{%s} %s\n' "$metric_prefix" "$labels" "$remediation_failed"
            printf '%s_service_incidents_total{%s} %s\n' "$metric_prefix" "$labels" "$incidents"
            printf '%s_service_current_incident_duration_seconds{%s} %s\n' "$metric_prefix" "$labels" "$incident_duration"
            printf '%s_service_last_incident_duration_seconds{%s} %s\n' "$metric_prefix" "$labels" "$last_incident_duration"
            printf '%s_service_last_success_timestamp{%s} %s\n' "$metric_prefix" "$labels" "$last_success"
            printf '%s_service_escalations_total{%s} %s\n' "$metric_prefix" "$labels" "$escalations"
            printf '%s_service_blocked_dependency_total{%s} %s\n' "$metric_prefix" "$labels" "$blocked_dependency"
            printf '%s_service_blocked_backoff_total{%s} %s\n' "$metric_prefix" "$labels" "$blocked_backoff"
            printf '%s_service_blocked_flapping_total{%s} %s\n' "$metric_prefix" "$labels" "$blocked_flapping"
            printf '%s_service_flapping_active{%s} %s\n' "$metric_prefix" "$labels" "$flapping_active"
            printf '%s_service_backoff_remaining_seconds{%s} %s\n' "$metric_prefix" "$labels" "$backoff_remaining"
            if [[ "$check_type" == http ]]; then
                printf '%s_service_http_last_total_seconds{%s} %.3f\n' "$metric_prefix" "$labels" "$(LC_ALL=C awk -v milliseconds="$http_total_ms" 'BEGIN { print milliseconds / 1000 }')"
                printf '%s_service_http_latency_slo_seconds{%s} %.3f\n' "$metric_prefix" "$labels" "$(LC_ALL=C awk -v milliseconds="$http_latency_threshold_ms" 'BEGIN { print milliseconds / 1000 }')"
            fi
        done
    } >"$temporary" || { rm -f -- "$temporary"; log ERROR "result=metrics-failed file=${target} reason=write"; return 0; }
    chmod 0644 "$temporary" 2>/dev/null || true
    if mv -f -- "$temporary" "$target"; then
        log INFO "result=metrics-written file=${target} services=${service_count} metrics=22"
    else
        rm -f -- "$temporary"
        log ERROR "result=metrics-failed file=${target} reason=rename"
    fi
}

escape_status_html() {
    local value="$1"
    value="${value//&/\&amp;}"; value="${value//</\&lt;}"; value="${value//>/\&gt;}"; value="${value//\"/\&quot;}"
    printf '%s' "$value"
}

format_status_timestamp() {
    local timestamp="$1"
    [[ "$timestamp" =~ ^[0-9]+$ && "$timestamp" != 0 ]] || { printf '%s' 'Never'; return; }
    date -d "@${timestamp}" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf '%s' 'Unknown'
}

status_page_overall_status() {
    local service_count index state degraded=0
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        state="$(read_state "$(yaml_read ".services[$index].name")")"
        [[ "$state" == unavailable ]] && { printf '%s' major_outage; return; }
        [[ "$state" == dependency_failed || "$state" == degraded || "$state" == recovering || "$state" == unknown ]] && degraded=1
    done
    (( degraded == 1 )) && printf '%s' degraded || printf '%s' operational
}

status_page_uptime_visual_state() {
    case "$1" in
        healthy) printf '%s' healthy ;;
        unavailable|dependency_failed) printf '%s' down ;;
        degraded|recovering) printf '%s' warning ;;
        *) printf '%s' unknown ;;
    esac
}

status_page_load_uptime_history() {
    local now="$1" timestamp service_name state epoch bucket key previous_epoch

    (( STATUS_PAGE_UPTIME_ENABLED == 1 )) || return 0
    STATUS_PAGE_UPTIME_CUTOFF=$((now - STATUS_PAGE_UPTIME_DAYS * 86400))
    STATUS_PAGE_UPTIME_BUCKET_SECONDS=$(((STATUS_PAGE_UPTIME_DAYS * 86400 + STATUS_PAGE_UPTIME_BUCKETS - 1) / STATUS_PAGE_UPTIME_BUCKETS))
    STATUS_PAGE_UPTIME_STATE=()
    STATUS_PAGE_UPTIME_EPOCH=()
    STATUS_PAGE_UPTIME_OBSERVED=()
    while IFS=$'\t' read -r timestamp service_name state; do
        [[ "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
        epoch="$(date -d "$timestamp" '+%s' 2>/dev/null)" || continue
        (( epoch >= STATUS_PAGE_UPTIME_CUTOFF && epoch <= now )) || continue
        bucket=$(((epoch - STATUS_PAGE_UPTIME_CUTOFF) / STATUS_PAGE_UPTIME_BUCKET_SECONDS))
        (( bucket < STATUS_PAGE_UPTIME_BUCKETS )) || bucket=$((STATUS_PAGE_UPTIME_BUCKETS - 1))
        key="${service_name}:${bucket}"
        previous_epoch="${STATUS_PAGE_UPTIME_EPOCH[$key]:-0}"
        (( epoch >= previous_epoch )) || continue
        STATUS_PAGE_UPTIME_STATE["$key"]="$(status_page_uptime_visual_state "$state")"
        STATUS_PAGE_UPTIME_EPOCH["$key"]="$epoch"
        STATUS_PAGE_UPTIME_OBSERVED["$key"]=1
    done < <(history_rows)
}

status_page_uptime_bar() {
    local service_name="$1" bucket key state label class summary percent
    local observed=0 healthy=0

    (( STATUS_PAGE_UPTIME_ENABLED == 1 )) || return 0
    for ((bucket = 0; bucket < STATUS_PAGE_UPTIME_BUCKETS; bucket++)); do
        key="${service_name}:${bucket}"
        [[ "${STATUS_PAGE_UPTIME_OBSERVED[$key]:-0}" == 1 ]] || continue
        observed=$((observed + 1))
        [[ "${STATUS_PAGE_UPTIME_STATE[$key]:-unknown}" == healthy ]] && healthy=$((healthy + 1))
    done
    if (( observed == 0 )); then
        summary="No observations in the last ${STATUS_PAGE_UPTIME_DAYS} days"
    else
        percent="$(LC_ALL=C awk -v healthy="$healthy" -v observed="$observed" 'BEGIN { printf "%.1f", 100 * healthy / observed }')"
        summary="Observed availability: ${percent}% (${healthy}/${observed} observed intervals; last ${STATUS_PAGE_UPTIME_DAYS} days)"
    fi
    printf '<div class="uptime"><small class="uptime-summary">%s</small><div class="uptime-bars" style="grid-template-columns:repeat(%s,minmax(4px,1fr))" role="img" aria-label="Observed availability for %s over the last %s days">' \
        "$(escape_status_html "$summary")" "$STATUS_PAGE_UPTIME_BUCKETS" "$(escape_status_html "$service_name")" "$STATUS_PAGE_UPTIME_DAYS"
    for ((bucket = 0; bucket < STATUS_PAGE_UPTIME_BUCKETS; bucket++)); do
        key="${service_name}:${bucket}"
        state="${STATUS_PAGE_UPTIME_STATE[$key]:-unknown}"
        if [[ "${STATUS_PAGE_UPTIME_OBSERVED[$key]:-0}" != 1 ]]; then
            class='uptime-unknown'; label='No observation'
        else
            case "$state" in
                healthy) class='uptime-healthy'; label='Observed healthy' ;;
                down) class='uptime-down'; label='Observed unavailable' ;;
                warning) class='uptime-warning'; label='Observed degraded' ;;
                *) class='uptime-unknown'; label='Observed unknown' ;;
            esac
        fi
        printf '<span class="uptime-bar %s" title="%s"></span>' "$class" "$label"
    done
    printf '</div></div>\n'
}

status_page_service_card() {
    local service_name="$1" check_type="$2" state="$3" last_check="$4" last_transition="$5" label class
    case "$state" in
        healthy) label='Operational'; class='healthy' ;;
        unavailable) label='Down'; class='down' ;;
        dependency_failed) label='Dependency Failed'; class='warning' ;;
        degraded) label='Degraded'; class='warning' ;;
        recovering) label='Recovering'; class='warning' ;;
        *) label='Unknown'; class='warning' ;;
    esac
    printf '<article class="service"><div><strong>%s</strong><small>%s · last check: %s · changed: %s</small></div><span class="status %s">● %s</span>' \
        "$(escape_status_html "$service_name")" "$(escape_status_html "$check_type")" \
        "$(escape_status_html "$(format_status_timestamp "$last_check")")" \
        "$(escape_status_html "$(format_status_timestamp "$last_transition")")" "$class" "$label"
    status_page_uptime_bar "$service_name"
    printf '</article>\n'
}

generate_status_page() {
    local target html_tmp json_tmp service_count index service_name check_type state last_check last_transition
    local title description logo footer refresh primary danger warning bg card text_color muted overall overall_label overall_class generated
    (( STATUS_PAGE_ENABLED == 1 )) || return 0
    if (( DRY_RUN == 1 )); then
        log INFO 'result=status-page-skipped reason=dry-run'
        return 0
    fi
    target="${STATUS_PAGE_DIRECTORY}/${STATUS_PAGE_HTML_FILENAME}"
    if [[ ! -d "$STATUS_PAGE_DIRECTORY" ]] && ! mkdir -p -- "$STATUS_PAGE_DIRECTORY" 2>/dev/null; then
        log ERROR "result=status-page-failed file=${target} reason=directory-not-writable"; return 0
    fi
    [[ -w "$STATUS_PAGE_DIRECTORY" ]] || { log ERROR "result=status-page-failed file=${target} reason=directory-not-writable"; return 0; }
    html_tmp="$(mktemp "${STATUS_PAGE_DIRECTORY}/.${STATUS_PAGE_HTML_FILENAME}.XXXXXX" 2>/dev/null)" || { log ERROR "result=status-page-failed file=${target} reason=temporary-file"; return 0; }
    title="$(yaml_read '.status_page.title // "Service Status"')"; description="$(yaml_read '.status_page.description // "Current availability of monitored services"')"
    logo="$(yaml_read '.status_page.logo_url // ""')"; footer="$(yaml_read '.status_page.footer // "Powered by Watchdog"')"; refresh="$(yaml_read '.status_page.auto_refresh // 0')"
    primary="$(yaml_read '.status_page.theme.primary // "2563eb"')"; danger="$(yaml_read '.status_page.theme.danger // "dc2626"')"; warning="$(yaml_read '.status_page.theme.warning // "f59e0b"')"; bg="$(yaml_read '.status_page.theme.bg // "f8fafc"')"; card="$(yaml_read '.status_page.theme.card // "ffffff"')"; text_color="$(yaml_read '.status_page.theme.text // "1e293b"')"; muted="$(yaml_read '.status_page.theme.muted // "64748b"')"
    overall="$(status_page_overall_status)"; generated="$(date '+%Y-%m-%d %H:%M:%S %z')"; service_count="$(yaml_read '.services | length')"
    status_page_load_uptime_history "$(date '+%s')"
    case "$overall" in operational) overall_label='All Systems Operational'; overall_class='healthy' ;; major_outage) overall_label='Major Outage'; overall_class='down' ;; *) overall_label='Partial Outage'; overall_class='warning' ;; esac
    {
        printf '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\n'
        (( refresh > 0 )) && printf '<meta http-equiv="refresh" content="%s">\n' "$refresh"
        printf '<title>%s</title><style>:root{--p:#%s;--d:#%s;--w:#%s;--bg:#%s;--card:#%s;--text:#%s;--muted:#%s}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}.wrap{max-width:850px;margin:auto;padding:32px 18px}header{text-align:center;margin-bottom:26px}h1{margin:8px 0}p,small,footer{color:var(--muted)}.overall,.service{background:var(--card);border-radius:12px;padding:16px;margin:12px 0;box-shadow:0 1px 3px #0001}.overall{text-align:center;font-weight:700}.service{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:16px}.service small{display:block;margin-top:5px}.status{white-space:nowrap}.uptime{display:grid;gap:6px;width:100%%}.uptime-summary{font-size:13px}.uptime-bars{display:grid;gap:3px}.uptime-bar{height:9px;border-radius:2px;background:#cbd5e1}.uptime-healthy{background:var(--p)}.uptime-down{background:var(--d)}.uptime-warning{background:var(--w)}.uptime-unknown{background:#cbd5e1}.healthy{color:var(--p)}.down{color:var(--d)}.warning{color:var(--w)}footer{text-align:center;margin-top:28px;font-size:13px}@media(max-width:550px){.service{align-items:flex-start;flex-direction:column;gap:7px}}</style></head><body><main class="wrap"><header>' "$(escape_status_html "$title")" "$primary" "$danger" "$warning" "$bg" "$card" "$text_color" "$muted"
        [[ -z "$logo" ]] || printf '<img src="%s" alt="" style="max-height:56px">' "$(escape_status_html "$logo")"
        printf '<h1>%s</h1><p>%s</p></header><div class="overall %s">%s</div><section><h2>Services</h2>\n' "$(escape_status_html "$title")" "$(escape_status_html "$description")" "$overall_class" "$overall_label"
        for ((index = 0; index < service_count; index++)); do
            service_name="$(yaml_read ".services[$index].name")"; check_type="$(service_check_type "$index")"; state="$(read_state "$service_name")"
            last_check="$(read_service_marker_number "$service_name" last-check 0)"; last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
            status_page_service_card "$service_name" "$check_type" "$state" "$last_check" "$last_transition"
        done
        printf '</section><footer>%s<br>Generated by Watchdog at %s</footer></main></body></html>\n' "$(escape_status_html "$footer")" "$generated"
    } >"$html_tmp" || { rm -f -- "$html_tmp"; log ERROR "result=status-page-failed file=${target} reason=write"; return 0; }
    chmod 0644 "$html_tmp" 2>/dev/null || true; mv -f -- "$html_tmp" "$target" || { rm -f -- "$html_tmp"; log ERROR "result=status-page-failed file=${target} reason=rename"; return 0; }
    if [[ -n "$STATUS_PAGE_JSON_FILENAME" ]]; then
        json_tmp="$(mktemp "${STATUS_PAGE_DIRECTORY}/.${STATUS_PAGE_JSON_FILENAME}.XXXXXX" 2>/dev/null)" || return 0
        { printf '{\n  "generated_at": "%s",\n  "overall_status": "%s",\n  "services": [\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$overall"
          for ((index = 0; index < service_count; index++)); do service_name="$(yaml_read ".services[$index].name")"; check_type="$(service_check_type "$index")"; state="$(read_state "$service_name")"; last_check="$(read_service_marker_number "$service_name" last-check 0)"; last_transition="$(read_service_marker_number "$service_name" last-transition 0)"; printf '    {"name":"%s","status":"%s","check_type":"%s","last_check":"%s","last_transition":"%s"}%s\n' "$(escape_json "$service_name")" "$state" "$check_type" "$(format_status_timestamp "$last_check")" "$(format_status_timestamp "$last_transition")" "$([[ $index -lt $((service_count - 1)) ]] && printf ',' )"; done
          printf '  ]\n}\n'; } >"$json_tmp" && { chmod 0644 "$json_tmp" 2>/dev/null || true; mv -f -- "$json_tmp" "${STATUS_PAGE_DIRECTORY}/${STATUS_PAGE_JSON_FILENAME}"; }
    fi
    log INFO "result=status-page-written file=${target} services=${service_count} overall=${overall}"
}

increment_unavailable_counter() {
    local service_name="$1" current
    (( DRY_RUN == 0 )) || return 0
    current="$(read_service_marker_number "$service_name" unavailable-count 0)"
    ESCALATION_CONSECUTIVE_UNAVAILABLE=$((10#$current + 1))
    write_service_marker_number "$service_name" unavailable-count "$ESCALATION_CONSECUTIVE_UNAVAILABLE"
    ESCALATION_COUNT="$(read_service_marker_number "$service_name" escalation-count 0)"
    log WARN "service=${service_name} state=unavailable consecutive_unavailable=${ESCALATION_CONSECUTIVE_UNAVAILABLE}"
}

reset_unavailable_counter() {
    local service_name="$1" current last_file index level_count level
    (( DRY_RUN == 0 )) || return 0
    current="$(read_service_marker_number "$service_name" unavailable-count 0)"
    ESCALATION_CONSECUTIVE_UNAVAILABLE=0
    ESCALATION_COUNT=0
    write_service_marker_number "$service_name" unavailable-count 0
    write_service_marker_number "$service_name" escalation-count 0
    last_file="$(maintenance_marker_file "$service_name" last-escalation)"
    rm -f -- "$last_file"
    rm -f -- "$(maintenance_marker_file "$service_name" manual-block)"
    write_service_marker_number "$service_name" failed-remediations-consecutive 0
    index="${SERVICE_INDEX[$service_name]}"
    level_count="$(yaml_read ".services[$index].escalation.levels // [] | length")"
    for ((level = 0; level < level_count; level++)); do
        rm -f -- "$(maintenance_marker_file "$service_name" "escalation-level-${level}")"
    done
    if (( 10#$current > 0 )); then
        log INFO "service=${service_name} state=healthy consecutive_unavailable=0 action=reset"
    fi
}

escalation_threshold_met() {
    local expression="$1" service_name="$2" field threshold now started failures
    now="$(date '+%s')"
    started="$(incident_read_field "$service_name" started_at 0)"
    failures="$(read_service_marker_number "$service_name" failed-remediations-consecutive 0)"
    for field in after_consecutive_unavailable after_duration_seconds after_failed_remediations; do
        threshold="$(yaml_read "${expression}.${field} // 0")"
        is_positive_integer "$threshold" || continue
        case "$field" in
            after_consecutive_unavailable) (( ESCALATION_CONSECUTIVE_UNAVAILABLE >= 10#$threshold )) && return 0 ;;
            after_duration_seconds) (( 10#$started > 0 && now >= 10#$started && now - 10#$started >= 10#$threshold )) && return 0 ;;
            after_failed_remediations) (( 10#$failures >= 10#$threshold )) && return 0 ;;
        esac
    done
    return 1
}

should_escalate() {
    local index="$1" service_name="$2" cooldown cooldown_value last_escalation now remaining
    [[ "$(yaml_read ".services[$index].escalation.enabled // false")" == true ]] || return 1
    escalation_threshold_met ".services[$index].escalation" "$service_name" || return 1
    cooldown="$(yaml_read ".services[$index].escalation.cooldown // 0")"
    cooldown_value=$((10#$cooldown))
    last_escalation="$(read_service_marker_number "$service_name" last-escalation 0)"
    (( cooldown_value == 0 || 10#$last_escalation == 0 )) && return 0
    now="$(date '+%s')"
    if (( now - 10#$last_escalation >= cooldown_value )); then
        return 0
    fi
    remaining=$((cooldown_value - (now - 10#$last_escalation)))
    log INFO "service=${service_name} event=escalation action=skipped reason=cooldown active=true remaining=${remaining}"
    return 1
}

run_escalation() {
    local index="$1" service_name="$2" notify_only="${3:-false}" cooldown notify last_escalation current_count
    local level_count level expression marker manual
    [[ "$(yaml_read ".services[$index].escalation.enabled // false")" == true ]] || return 0
    if (( MAINTENANCE_ACTIVE == 1 )); then
        log INFO "service=${service_name} event=escalation action=skipped reason=maintenance-window"
        return 0
    fi
    level_count="$(yaml_read ".services[$index].escalation.levels // [] | length")"
    for ((level = 0; level < level_count; level++)); do
        expression=".services[$index].escalation.levels[$level]"
        escalation_threshold_met "$expression" "$service_name" || continue
        marker="$(maintenance_marker_file "$service_name" "escalation-level-${level}")"
        [[ ! -e "$marker" ]] || continue
        if (( DRY_RUN == 1 )); then
            log WARN "service=${service_name} event=escalation level=$((level + 1)) action=would-trigger"
            if [[ "$(yaml_read_true_default "${expression}.notify")" == true ]]; then
                log_notification_plan "$service_name" escalation
            fi
            continue
        fi
        write_service_marker_number "$service_name" "escalation-level-${level}" "$(date '+%s')"
        increment_service_marker_number "$service_name" escalation-count
        increment_service_marker_number "$service_name" escalations-total
        ESCALATION_COUNT="$(read_service_marker_number "$service_name" escalation-count 0)"
        notify="$(yaml_read_true_default "${expression}.notify")"
        if [[ "$notify" == true ]]; then
            send_email_notification escalation || log ERROR "service=${service_name} result=escalation-email-failed level=${level}"
            send_webhook_notification escalation || log ERROR "service=${service_name} result=escalation-webhook-failed level=${level}"
        fi
        manual="$(yaml_read "${expression}.manual_intervention // false")"
        [[ "$manual" == true ]] && write_service_marker_string "$service_name" manual-block true
        log WARN "service=${service_name} event=escalation level=$((level + 1)) action=triggered manual_intervention=${manual}"
    done
    if flapping_is_active "$service_name" ||
        [[ "$(read_service_marker_string "$service_name" manual-block false)" == true ]] ||
        [[ "$(read_service_marker_string "$service_name" circuit-state closed)" == open ]]; then
        notify_only=true
        log INFO "service=${service_name} event=escalation action=commands-skipped reason=remediation-guard"
    fi
    should_escalate "$index" "$service_name" || return 0
    if (( DRY_RUN == 1 )); then
        log WARN "service=${service_name} event=escalation action=would-trigger"
        if [[ "$notify_only" != true ]]; then
            log_configured_sequence_plan ".services[$index].escalation.actions.commands" escalation "$service_name"
            log_configured_sequence_plan ".services[$index].escalation.hooks.on_escalation" escalation-hook "$service_name"
        fi
        if [[ "$(yaml_read_true_default ".services[$index].escalation.notify")" == true ]]; then
            log_notification_plan "$service_name" escalation
        fi
        return 0
    fi
    cooldown="$(yaml_read ".services[$index].escalation.cooldown // 0")"
    current_count="$(read_service_marker_number "$service_name" escalation-count 0)"
    ESCALATION_COUNT=$((10#$current_count + 1))
    log WARN "service=${service_name} event=escalation consecutive_unavailable=${ESCALATION_CONSECUTIVE_UNAVAILABLE} cooldown=${cooldown} action=triggered"
    if [[ "$notify_only" != true ]]; then
        if ! run_configured_sequence ".services[$index].escalation.actions.commands" escalation "$service_name"; then
            log ERROR "service=${service_name} event=escalation action=commands-failed"
        fi
    fi
    notify="$(yaml_read_true_default ".services[$index].escalation.notify")"
    if [[ "$notify" == true ]]; then
        send_email_notification escalation || log ERROR "service=${service_name} result=escalation-email-failed"
        send_webhook_notification escalation || log ERROR "service=${service_name} result=escalation-webhook-failed"
    fi
    if [[ "$notify_only" != true ]]; then
        if ! run_configured_sequence ".services[$index].escalation.hooks.on_escalation" escalation "$service_name"; then
            log ERROR "service=${service_name} event=escalation action=hook-failed"
        fi
    fi
    [[ "$(yaml_read ".services[$index].escalation.manual_intervention // false")" == true ]] &&
        write_service_marker_string "$service_name" manual-block true
    last_escalation="$(date '+%s')"
    write_service_marker_number "$service_name" escalation-count "$ESCALATION_COUNT"
    increment_service_marker_number "$service_name" escalations-total
    write_service_marker_number "$service_name" last-escalation "$last_escalation"
    log WARN "service=${service_name} event=escalation consecutive_unavailable=${ESCALATION_CONSECUTIVE_UNAVAILABLE} action=executed"
}

is_maintenance_window() {
    local service_name="$1" service_count index name timezone day now days time start end window_count window
    local matched_day normalized_day

    MAINTENANCE_WINDOW_NAME=""
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        name="$(yaml_read ".services[$index].name")"
        [[ "$name" == "$service_name" ]] && break
    done
    (( index < service_count )) || return 1
    window_count="$(yaml_read ".services[$index].maintenance.windows // [] | length")"
    (( window_count > 0 )) || return 1
    timezone="$(yaml_read ".services[$index].maintenance.timezone // \"\"")"
    if [[ -n "$timezone" ]]; then
        day="$(TZ="$timezone" LC_ALL=C date '+%a')"
        now="$(TZ="$timezone" date '+%H:%M')"
    else
        day="$(LC_ALL=C date '+%a')"
        now="$(date '+%H:%M')"
    fi
    day="${day,,}"
    for ((window = 0; window < window_count; window++)); do
        days="$(yaml_read ".services[$index].maintenance.windows[$window].days")"
        time="$(yaml_read ".services[$index].maintenance.windows[$window].time")"
        matched_day=0
        if [[ "$days" == "*" ]]; then
            matched_day=1
        else
            IFS=',' read -r -a maintenance_days <<<"$days"
            for normalized_day in "${maintenance_days[@]}"; do
                [[ "${normalized_day,,}" == "$day" ]] && matched_day=1
            done
        fi
        start="${time%-*}"; end="${time#*-}"
        if (( matched_day == 1 )) && [[ "$now" > "$start" || "$now" == "$start" ]] && [[ "$now" < "$end" ]]; then
            MAINTENANCE_WINDOW_NAME="$(yaml_read ".services[$index].maintenance.windows[$window].name // \"window-${window}\"")"
            return 0
        fi
    done
    return 1
}

update_maintenance_status() {
    local service_name="$1" active_file
    MAINTENANCE_ACTIVE=0
    if ! is_maintenance_window "$service_name"; then
        record_maintenance_exit "$service_name"
        return 0
    fi
    MAINTENANCE_ACTIVE=1
    (( DRY_RUN == 0 )) || return 0
    active_file="$(maintenance_marker_file "$service_name" maintenance-active)"
    if [[ ! -e "$active_file" ]]; then
        printf '%s\n' "$MAINTENANCE_WINDOW_NAME" >"$active_file" || die "Cannot write maintenance state: ${active_file}"
        log INFO "service=${service_name} maintenance_window=${MAINTENANCE_WINDOW_NAME} active=true"
    fi
}

record_maintenance_exit() {
    local service_name="$1" active_file previous_window="previous"
    (( DRY_RUN == 0 )) || return 0
    active_file="$(maintenance_marker_file "$service_name" maintenance-active)"
    if [[ -e "$active_file" ]]; then
        if [[ -s "$active_file" ]]; then
            IFS= read -r previous_window <"$active_file" || true
        fi
        rm -f -- "$active_file"
        log INFO "service=${service_name} maintenance_window=${previous_window} active=false"
    fi
}

send_deferred_failure_alert() {
    local service_name="$1" deferred_file
    (( DRY_RUN == 0 && MAINTENANCE_ACTIVE == 0 )) || return 0
    deferred_file="$(maintenance_marker_file "$service_name" maintenance-deferred-failure)"
    [[ -e "$deferred_file" ]] || return 0
    [[ "$(read_state "$service_name")" == unavailable ]] || { rm -f -- "$deferred_file"; return 0; }
    log WARN "service=${service_name} state=unavailable maintenance=deferred_alert action=send"
    send_email_notification failure || log ERROR "service=${service_name} result=state-email-failed state=unavailable"
    send_webhook_notification failure || log ERROR "service=${service_name} result=state-webhook-failed state=unavailable"
    run_configured_sequence '.hooks.on_failure' unavailable "$service_name" ||
        log ERROR "service=${service_name} result=state-hook-failed state=unavailable"
    rm -f -- "$deferred_file"
}

handle_state_transition() {
    local service_name="$1" new_state="$2"
    local previous hook_expression notification_event deferred_file incident_result=""
    previous="$(read_state "$service_name")"
    if (( DRY_RUN == 1 )); then
        if [[ "$previous" != "$new_state" ]]; then
            log INFO "service=${service_name} action=state result=would-transition previous=${previous} current=${new_state}"
            if (( MAINTENANCE_ACTIVE == 1 )); then
                log INFO "service=${service_name} action=notification result=would-suppress reason=maintenance-window"
            elif [[ "$new_state" == unavailable || ( "$new_state" == degraded && ( "$previous" == healthy || "$previous" == unknown ) ) ]]; then
                log_notification_plan "$service_name" failure
                log_configured_sequence_plan '.hooks.on_failure' failure "$service_name"
            elif [[ "$new_state" == healthy && "$previous" != unknown ]]; then
                log_notification_plan "$service_name" recovery
                log_configured_sequence_plan '.hooks.on_recovery' recovery "$service_name"
            fi
        fi
        return 0
    fi
    if [[ "$previous" == "$new_state" ]]; then
        incident_update "$service_name" "$new_state" heartbeat
        [[ "$new_state" == unavailable ]] && send_deferred_failure_alert "$service_name"
        return 0
    fi
    if (( MAINTENANCE_ACTIVE == 1 )); then
        deferred_file="$(maintenance_marker_file "$service_name" maintenance-deferred-failure)"
        if [[ "$new_state" == unavailable ]]; then
            : >"$deferred_file" || die "Cannot write maintenance state: ${deferred_file}"
        else
            rm -f -- "$deferred_file"
        fi
        write_state "$service_name" "$new_state"
        record_state_transition_timestamp "$service_name"
        flapping_record_transition "${SERVICE_INDEX[$service_name]}" "$service_name"
        incident_update "$service_name" "$new_state" transition
        log INFO "service=${service_name} event=state-change state=${new_state} maintenance_window=${MAINTENANCE_WINDOW_NAME} action=suppressed"
        return 0
    fi
    hook_expression=""
    notification_event=""
    case "$CURRENT_ACTION_STATUS" in
        successful|command-failed|verification-failed|liveness-restored-readiness-pending) incident_result="$CURRENT_ACTION_STATUS" ;;
    esac
    if [[ "$new_state" == unavailable ]]; then
        hook_expression='.hooks.on_failure'
        notification_event=failure
    elif [[ "$new_state" == degraded && ( "$previous" == healthy || "$previous" == unknown ) ]]; then
        hook_expression='.hooks.on_failure'
        notification_event=failure
    elif [[ "$new_state" == healthy && "$previous" != healthy && "$previous" != unknown ]]; then
        hook_expression='.hooks.on_recovery'
        notification_event=recovery
    fi
    write_state "$service_name" "$new_state"
    record_state_transition_timestamp "$service_name"
    flapping_record_transition "${SERVICE_INDEX[$service_name]}" "$service_name"
    incident_update "$service_name" "$new_state" transition "$incident_result"
    if [[ -n "$notification_event" ]]; then
        send_email_notification "$notification_event" ||
            log ERROR "service=${service_name} result=state-email-failed state=${new_state}"
        send_webhook_notification "$notification_event" ||
            log ERROR "service=${service_name} result=state-webhook-failed state=${new_state}"
    fi
    if [[ -n "$hook_expression" ]]; then
        run_configured_sequence "$hook_expression" "${new_state}" "$service_name" ||
            log ERROR "service=${service_name} result=state-hook-failed state=${new_state}"
    fi
    log INFO "service=${service_name} action=state previous=${previous} current=${new_state}"
}

handle_dependency_failure() {
    local service_name="$1" dependency_name="$2" previous
    previous="$(read_state "$service_name")"
    if (( DRY_RUN == 0 )); then
        write_service_marker_string "$service_name" blocked-by "$dependency_name"
        increment_service_marker_number "$service_name" blocked-dependency-total
    fi
    if [[ "$previous" == unavailable ]]; then
        PROCESS_RESULT=unavailable
        log WARN "service=${service_name} state=unavailable dependency=${dependency_name} note=already_unavailable_before_dependency"
        return 0
    fi
    (( DRY_RUN == 0 )) || { PROCESS_RESULT=dependency_failed; return 0; }
    write_state "$service_name" dependency_failed
    record_state_transition_timestamp "$service_name"
    incident_update "$service_name" dependency_failed blocked
    PROCESS_RESULT=dependency_failed
    log WARN "service=${service_name} state=dependency_failed dependency=${dependency_name} reason=required_dependency_unavailable"
}

required_dependency_is_unavailable() {
    local service_name="$1" dependency_name dependency_state required
    for dependency_name in ${DEPENDENCY_NAMES[$service_name]:-}; do
        dependency_state="${RESOLVED_STATE[$dependency_name]:-unknown}"
        required="${DEPENDENCY_REQUIRED[${service_name}:${dependency_name}]:-true}"
        if [[ "$dependency_state" == unavailable || "$dependency_state" == dependency_failed || "$dependency_state" == degraded || "$dependency_state" == recovering ]]; then
            if [[ "$required" == true ]]; then
                log WARN "service=${service_name} dependency=${dependency_name} required=true dependency_state=${dependency_state} action=skip reason=dependency_failed"
                printf '%s' "$dependency_name"
                return 0
            fi
            log WARN "service=${service_name} dependency=${dependency_name} required=false dependency_state=${dependency_state} action=proceed reason=optional_dependency_down"
        fi
    done
    return 1
}

service_is_required_for() {
    local target_service="$1" candidate_service="$2" dependency_name
    for dependency_name in ${DEPENDENCY_NAMES[$target_service]:-}; do
        [[ "$dependency_name" == "$candidate_service" ]] && return 0
        service_is_required_for "$dependency_name" "$candidate_service" && return 0
    done
    return 1
}

process_service() {
    local index="$1"
    local enabled actions_count verify_after action_due=0 half_open_attempt=0 initial_check_healthy=0 initial_check_degraded=0 has_readiness=0
    CURRENT_SERVICE="$(yaml_read ".services[$index].name")"
    if [[ "$(yaml_read ".services[$index].health | type")" == '!!map' ]]; then
        has_readiness=1
        CHECK_CONFIG_PATH=".services[$index].health.liveness"
    else
        CHECK_CONFIG_PATH=".services[$index].check"
    fi
    CURRENT_CHECK_TYPE="$(yaml_read "${CHECK_CONFIG_PATH}.type")"
    CURRENT_ACTION_STATUS="not-attempted"
    INCIDENT_ID="$(incident_read_field "$CURRENT_SERVICE" id "")"
    INCIDENT_DURATION="$(incident_read_field "$CURRENT_SERVICE" duration_seconds 0)"
    INCIDENT_REMEDIATION_RESULT="$(incident_read_field "$CURRENT_SERVICE" remediation_result not-attempted)"
    PROCESS_RESULT="unknown"
    ESCALATION_CONSECUTIVE_UNAVAILABLE=0
    ESCALATION_COUNT=0
    CHECK_DETAIL=""
    CHECK_HTTP_STATUS=""
    CHECK_HTTP_TOTAL_MS=""
    CHECK_HTTP_MAX_TOTAL_MS=""
    CHECK_RESULT_STATE=unavailable
    CHECK_EXIT_CODE=""
    MATCH_COUNT=""
    THRESHOLD_VALUE=""
    THRESHOLD_COMPARATOR=""
    THRESHOLD_SINCE=""
    enabled="$(yaml_read_true_default ".services[$index].enabled")"

    if [[ "$enabled" != true ]]; then
        log INFO "service=${CURRENT_SERVICE} result=skipped reason=disabled"
        PROCESS_RESULT="$(read_state "$CURRENT_SERVICE")"
        return 0
    fi

    local failed_dependency=""
    failed_dependency="$(required_dependency_is_unavailable "$CURRENT_SERVICE")" || true
    if [[ -n "$failed_dependency" ]]; then
        handle_dependency_failure "$CURRENT_SERVICE" "$failed_dependency"
        return 0
    fi
    (( DRY_RUN == 1 )) || rm -f -- "$(maintenance_marker_file "$CURRENT_SERVICE" blocked-by)"

    if [[ -n "${CONDITION_SKIPPED[$CURRENT_SERVICE]+present}" ]]; then
        PROCESS_RESULT="$(read_state "$CURRENT_SERVICE")"
        return 0
    fi
    if [[ -z "${CONDITION_EVALUATED[$CURRENT_SERVICE]+present}" ]] && ! evaluate_conditions "$index" "$CURRENT_SERVICE"; then
        PROCESS_RESULT="$(read_state "$CURRENT_SERVICE")"
        return 0
    fi

    log INFO "service=${CURRENT_SERVICE} action=service-start type=${CURRENT_CHECK_TYPE}"
    if [[ -n "${PRELOADED_CHECK_STATE[$CURRENT_SERVICE]+present}" ]]; then
        use_preloaded_check_result "$CURRENT_SERVICE" && initial_check_healthy=1
    elif check_with_retries "$index"; then
        initial_check_healthy=1
    fi
    [[ "$CHECK_RESULT_STATE" == degraded ]] && initial_check_degraded=1
    if (( initial_check_healthy == 1 )); then
        if (( has_readiness == 1 )); then
            CHECK_CONFIG_PATH=".services[$index].health.readiness"
            CURRENT_CHECK_TYPE="$(yaml_read "${CHECK_CONFIG_PATH}.type")"
            if ! check_with_retries "$index"; then
                if [[ "$CHECK_RESULT_STATE" == degraded ]]; then
                    CURRENT_ACTION_STATUS="latency-slo-exceeded"
                    update_maintenance_status "$CURRENT_SERVICE"
                    handle_state_transition "$CURRENT_SERVICE" degraded
                    PROCESS_RESULT=degraded
                    UNHEALTHY_FOUND=1
                    log WARN "service=${CURRENT_SERVICE} result=degraded action=remediation-skipped reason=latency-slo detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
                    return 0
                fi
                CURRENT_ACTION_STATUS="readiness-failed"
                update_maintenance_status "$CURRENT_SERVICE"
                if [[ "$(read_state "$CURRENT_SERVICE")" == recovering ]]; then
                    handle_state_transition "$CURRENT_SERVICE" recovering
                    PROCESS_RESULT=recovering
                else
                    handle_state_transition "$CURRENT_SERVICE" degraded
                    PROCESS_RESULT=degraded
                fi
                flapping_record_health "$index" "$CURRENT_SERVICE" false
                UNHEALTHY_FOUND=1
                run_escalation "$index" "$CURRENT_SERVICE" true
                log WARN "service=${CURRENT_SERVICE} result=readiness-failed action=remediation-skipped detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
                return 0
            fi
        fi
        CURRENT_ACTION_STATUS="not-required"
        update_maintenance_status "$CURRENT_SERVICE"
        record_circuit_action_result "$index" "$CURRENT_SERVICE" true
        reset_unavailable_counter "$CURRENT_SERVICE"
        backoff_reset "$index" "$CURRENT_SERVICE"
        handle_state_transition "$CURRENT_SERVICE" healthy
        flapping_record_health "$index" "$CURRENT_SERVICE" true
        PROCESS_RESULT=healthy
        log INFO "service=${CURRENT_SERVICE} result=healthy"
        return 0
    fi

    if (( initial_check_degraded == 1 )); then
        CURRENT_ACTION_STATUS="latency-slo-exceeded"
        update_maintenance_status "$CURRENT_SERVICE"
        handle_state_transition "$CURRENT_SERVICE" degraded
        PROCESS_RESULT=degraded
        UNHEALTHY_FOUND=1
        log WARN "service=${CURRENT_SERVICE} result=degraded action=remediation-skipped reason=latency-slo detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
        return 0
    fi

    update_maintenance_status "$CURRENT_SERVICE"
    actions_count="$(yaml_read ".services[$index].actions.commands // [] | length")"
    if (( actions_count == 0 )); then
        CURRENT_ACTION_STATUS="not-configured"
    elif (( MAINTENANCE_ACTIVE == 1 )); then
        CURRENT_ACTION_STATUS="skipped-maintenance"
    elif [[ "$(read_service_marker_string "$CURRENT_SERVICE" manual-block false)" == true ]]; then
        CURRENT_ACTION_STATUS="skipped-manual-intervention"
        log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=manual-intervention"
    elif ! should_run_actions_with_circuit_breaker "$index" "$CURRENT_SERVICE"; then
        CURRENT_ACTION_STATUS="skipped-circuit-breaker"
    elif ! action_is_due "$index" "$CURRENT_SERVICE"; then
        CURRENT_ACTION_STATUS="skipped-cooldown"
    elif ! backoff_is_due "$index" "$CURRENT_SERVICE"; then
        CURRENT_ACTION_STATUS="skipped-backoff"
        increment_service_marker_number "$CURRENT_SERVICE" blocked-backoff-total
    else
        action_due=1
        if (( DRY_RUN == 1 )); then
            CURRENT_ACTION_STATUS="would-run"
        else
            CURRENT_ACTION_STATUS="pending"
        fi
        if (( DRY_RUN == 0 )) && [[ "$(read_service_marker_string "$CURRENT_SERVICE" circuit-state closed)" == half_open ]]; then
            CURRENT_ACTION_STATUS="pending-half-open"
            half_open_attempt=1
        fi
    fi

    # Record and notify the incident before remediation. The state transition
    # guarantees that a continuing outage does not generate duplicate email.
    handle_state_transition "$CURRENT_SERVICE" unavailable
    flapping_record_health "$index" "$CURRENT_SERVICE" false
    if flapping_is_active "$CURRENT_SERVICE"; then
        action_due=0
        CURRENT_ACTION_STATUS="skipped-flapping"
        increment_service_marker_number "$CURRENT_SERVICE" blocked-flapping-total
        log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=flapping"
    fi

    if (( actions_count > 0 )); then
        if (( DRY_RUN == 1 )); then
            if (( action_due == 1 )); then
                log WARN "service=${CURRENT_SERVICE} action=remediation result=would-run reason=dry-run commands=${actions_count}"
                log_configured_sequence_plan ".services[$index].actions.commands" remediation "$CURRENT_SERVICE"
            else
                log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=${CURRENT_ACTION_STATUS} dry_run=true"
            fi
        elif (( MAINTENANCE_ACTIVE == 1 )); then
            log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=maintenance-window maintenance_window=${MAINTENANCE_WINDOW_NAME}"
        elif (( action_due == 1 )); then
            ACTION_ATTEMPTED=1
            record_action_attempt "$CURRENT_SERVICE"
            log WARN "service=${CURRENT_SERVICE} action=remediation-start commands=${actions_count}"
            if run_configured_sequence ".services[$index].actions.commands" remediation "$CURRENT_SERVICE"; then
                CURRENT_ACTION_STATUS="commands-succeeded"
            else
                CURRENT_ACTION_STATUS="command-failed"
            fi

            if (( half_open_attempt == 1 )); then
                verify_after="$(yaml_read ".services[$index].circuit_breaker.half_open_verify_after // 0")"
            else
                verify_after="$(yaml_read ".services[$index].actions.verify_after // 0")"
            fi
            (( verify_after > 0 )) && sleep "$verify_after"
            if check_with_retries "$index"; then
                if (( has_readiness == 1 )); then
                    CHECK_CONFIG_PATH=".services[$index].health.readiness"
                    CURRENT_CHECK_TYPE="$(yaml_read "${CHECK_CONFIG_PATH}.type")"
                    if ! check_with_retries "$index"; then
                        CURRENT_ACTION_STATUS="liveness-restored-readiness-pending"
                        handle_state_transition "$CURRENT_SERVICE" recovering
                        flapping_record_health "$index" "$CURRENT_SERVICE" false
                        backoff_record_failure "$index" "$CURRENT_SERVICE"
                        increment_service_marker_number "$CURRENT_SERVICE" failed-remediations-consecutive
                        increment_service_marker_number "$CURRENT_SERVICE" remediations-failed-total
                        run_escalation "$index" "$CURRENT_SERVICE" true
                        PROCESS_RESULT=recovering
                        UNHEALTHY_FOUND=1
                        log WARN "service=${CURRENT_SERVICE} result=recovering reason=readiness-failed"
                        return 0
                    fi
                fi
                CURRENT_ACTION_STATUS="successful"
                update_maintenance_status "$CURRENT_SERVICE"
                record_circuit_action_result "$index" "$CURRENT_SERVICE" true
                reset_unavailable_counter "$CURRENT_SERVICE"
                backoff_reset "$index" "$CURRENT_SERVICE"
                increment_service_marker_number "$CURRENT_SERVICE" remediations-success-total
                handle_state_transition "$CURRENT_SERVICE" healthy
                flapping_record_health "$index" "$CURRENT_SERVICE" true
                PROCESS_RESULT=healthy
                log WARN "service=${CURRENT_SERVICE} result=recovered-after-remediation"
                return 0
            fi
            if [[ "$CURRENT_ACTION_STATUS" == commands-succeeded ]]; then
                CURRENT_ACTION_STATUS="verification-failed"
            fi
            record_circuit_action_result "$index" "$CURRENT_SERVICE" false
            backoff_record_failure "$index" "$CURRENT_SERVICE"
            increment_service_marker_number "$CURRENT_SERVICE" failed-remediations-consecutive
            increment_service_marker_number "$CURRENT_SERVICE" remediations-failed-total
            incident_update "$CURRENT_SERVICE" unavailable result "$CURRENT_ACTION_STATUS"
        else
            if [[ "$CURRENT_ACTION_STATUS" == skipped-flapping ]]; then
                log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=flapping"
            elif [[ "$CURRENT_ACTION_STATUS" == skipped-circuit-breaker ]]; then
                log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=circuit-breaker"
            else
                log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=${CURRENT_ACTION_STATUS}"
            fi
        fi
    fi

    increment_unavailable_counter "$CURRENT_SERVICE"
    run_escalation "$index" "$CURRENT_SERVICE"
    PROCESS_RESULT=unavailable
    UNHEALTHY_FOUND=1
    log ERROR "service=${CURRENT_SERVICE} result=unavailable detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
    return 0
}
