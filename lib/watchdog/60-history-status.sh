history_capture_service() {
    local service_name="$1"
    (( HISTORY_ENABLED == 1 && DRY_RUN == 0 )) || return 0
    [[ -n "${HISTORY_CHECKED[$service_name]:-}" ]] || return 0
    HISTORY_SERVICES+=("$service_name")
    HISTORY_TIMESTAMP["$service_name"]="$(date -Iseconds)"
    HISTORY_STATE["$service_name"]="$PROCESS_RESULT"
    HISTORY_CHECK_TYPE["$service_name"]="$CURRENT_CHECK_TYPE"
    HISTORY_DETAIL["$service_name"]="$(sanitize_detail "$CHECK_DETAIL")"
    HISTORY_HTTP_STATUS["$service_name"]="$CHECK_HTTP_STATUS"
    HISTORY_CHECK_EXIT["$service_name"]="$CHECK_EXIT_CODE"
    HISTORY_ACTION_STATUS["$service_name"]="$CURRENT_ACTION_STATUS"
    HISTORY_DURATION["$service_name"]="${HISTORY_CHECK_DURATION[$service_name]:-0}"
}

history_field_value() {
    local field="$1" service_name="$2"
    case "$field" in
        timestamp) printf '%s' "${HISTORY_TIMESTAMP[$service_name]}" ;;
        node_id) printf '%s' "$HISTORY_NODE_ID" ;;
        service) printf '%s' "$service_name" ;;
        state) printf '%s' "${HISTORY_STATE[$service_name]}" ;;
        check_type) printf '%s' "${HISTORY_CHECK_TYPE[$service_name]}" ;;
        detail) printf '%s' "${HISTORY_DETAIL[$service_name]}" ;;
        http_status) printf '%s' "${HISTORY_HTTP_STATUS[$service_name]}" ;;
        check_exit) printf '%s' "${HISTORY_CHECK_EXIT[$service_name]}" ;;
        action_status) printf '%s' "${HISTORY_ACTION_STATUS[$service_name]}" ;;
        duration_sec) printf '%s' "${HISTORY_DURATION[$service_name]}" ;;
    esac
}

history_sql_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

history_field_literal() {
    local field="$1" value="$2" format="$3"
    if [[ "$field" == http_status || "$field" == check_exit || "$field" == duration_sec ]]; then
        if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s' "$((10#$value))"; else printf null; fi
    elif [[ "$format" == json ]]; then
        printf '"%s"' "$(escape_json "$value")"
    else
        history_sql_quote "$value"
    fi
}

rotate_history() {
    local file="$1" removed=0 lines temp
    (( HISTORY_ENABLED == 1 )) || return 0
    if [[ "$HISTORY_STORAGE" == sqlite ]]; then
        (( HISTORY_MAX_AGE_DAYS > 0 )) || return 0
        removed="$(sqlite3 -batch -bail "$HISTORY_PATH" "DELETE FROM checks WHERE datetime(timestamp) < datetime('now', '-${HISTORY_MAX_AGE_DAYS} days'); SELECT changes();")" || die 'history=error storage=sqlite reason=rotation-failed'
        log INFO "history=rotated storage=sqlite deleted=${removed} rows"
    elif [[ "$HISTORY_ROTATION_MODE" == daily ]]; then
        (( HISTORY_MAX_AGE_DAYS > 0 )) || return 0
        removed="$(find "$HISTORY_PATH" -maxdepth 1 -type f -name 'history_????-??-??.jsonl' -mmin "+$((HISTORY_MAX_AGE_DAYS * 1440))" -print -delete | wc -l)" ||
            die 'history=error storage=jsonl reason=rotation-failed'
        log INFO "history=rotated storage=jsonl deleted=${removed} mode=daily"
    elif (( HISTORY_MAX_RECORDS > 0 )); then
        lines="$(wc -l <"$file")"
        if (( lines > HISTORY_MAX_RECORDS )); then
            temp="$(mktemp "${file}.tmp.XXXXXX")" || die 'history=error storage=jsonl reason=rotation-temp-failed'
            tail -n "$HISTORY_MAX_RECORDS" -- "$file" >"$temp" || die 'history=error storage=jsonl reason=rotation-read-failed'
            chmod 0640 "$temp" 2>/dev/null || true
            mv -f -- "$temp" "$file" || die 'history=error storage=jsonl reason=rotation-move-failed'
            log INFO "history=rotated storage=jsonl truncated=$((lines - HISTORY_MAX_RECORDS)) mode=single"
        fi
    fi
}

write_history() {
    local service_name field value literal line comma file columns values
    (( HISTORY_ENABLED == 1 )) || { log INFO 'history=skipped reason=history.enabled=false'; return 0; }
    (( DRY_RUN == 0 )) || return 0
    (( ${#HISTORY_SERVICES[@]} > 0 )) || return 0
    HISTORY_NODE_ID="$(yaml_read '.federation.node_id // ""')"
    [[ -n "$HISTORY_NODE_ID" ]] || HISTORY_NODE_ID="$(hostname -s)"
    if [[ "$HISTORY_STORAGE" == jsonl ]]; then
        mkdir -p -- "$HISTORY_PATH" || die 'history=error storage=jsonl reason=mkdir-failed'
        if [[ "$HISTORY_ROTATION_MODE" == daily ]]; then
            file="${HISTORY_PATH}/history_$(date '+%Y-%m-%d').jsonl"
        else
            file="${HISTORY_PATH}/history.jsonl"
        fi
        for service_name in "${HISTORY_SERVICES[@]}"; do
            line='{'; comma=''
            for field in "${HISTORY_FIELDS[@]}"; do
                value="$(history_field_value "$field" "$service_name")"
                literal="$(history_field_literal "$field" "$value" json)"
                line+="${comma}\"${field}\":${literal}"; comma=,
            done
            line+='}'
            printf '%s\n' "$line" >>"$file" || die 'history=error storage=jsonl reason=append-failed'
        done
        chmod 0640 "$file" 2>/dev/null || true
        log INFO "history=written storage=jsonl file=${file} records=${#HISTORY_SERVICES[@]}"
    else
        mkdir -p -- "$(dirname -- "$HISTORY_PATH")" || die 'history=error storage=sqlite reason=mkdir-failed'
        {
            printf 'CREATE TABLE IF NOT EXISTS checks (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL, node_id TEXT, service TEXT NOT NULL, state TEXT NOT NULL, check_type TEXT, detail TEXT, http_status INTEGER, check_exit INTEGER, action_status TEXT, duration_sec INTEGER);\n'
            printf 'CREATE INDEX IF NOT EXISTS idx_checks_service_time ON checks(service, timestamp);\n'
            printf 'CREATE INDEX IF NOT EXISTS idx_checks_timestamp ON checks(timestamp);\n'
            printf 'BEGIN IMMEDIATE;\n'
            for service_name in "${HISTORY_SERVICES[@]}"; do
                columns=''; values=''; comma=''
                for field in "${HISTORY_FIELDS[@]}"; do
                    value="$(history_field_value "$field" "$service_name")"
                    literal="$(history_field_literal "$field" "$value" sql)"
                    columns+="${comma}${field}"; values+="${comma}${literal}"; comma=,
                done
                printf 'INSERT INTO checks (%s) VALUES (%s);\n' "$columns" "$values"
            done
            printf 'COMMIT;\n'
        } | sqlite3 -batch -bail "$HISTORY_PATH" >/dev/null || die 'history=error storage=sqlite reason=insert-failed'
        chmod 0640 "$HISTORY_PATH" 2>/dev/null || true
        log INFO "history=written storage=sqlite db=${HISTORY_PATH} records=${#HISTORY_SERVICES[@]}"
        file="$HISTORY_PATH"
    fi
    rotate_history "$file"
}

# Only the three mandatory, validated fields are needed for aggregate reports.
# A generated service name contains no tabs or JSON escapes, so awk can read
# these fields without adding jq or interpreting arbitrary check details.
history_rows() {
    local file
    if [[ "$HISTORY_STORAGE" == sqlite ]]; then
        [[ -f "$HISTORY_PATH" ]] || return 0
        sqlite3 -readonly -batch -bail -separator $'\t' "$HISTORY_PATH" 'SELECT timestamp, service, state FROM checks ORDER BY datetime(timestamp), id;' || return 1
    else
        if [[ "$HISTORY_ROTATION_MODE" == daily ]]; then
            for file in "$HISTORY_PATH"/history_????-??-??.jsonl; do
                [[ -f "$file" ]] || continue
                awk '
                    function field(key, text, pattern, value) {
                        pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
                        if (!match(text, pattern)) return ""
                        value = substr(text, RSTART, RLENGTH)
                        sub(/^.*:[[:space:]]*"/, "", value)
                        sub(/"$/, "", value)
                        return value
                    }
                    { t=field("timestamp",$0); s=field("service",$0); st=field("state",$0); if (t!="" && s!="" && st!="") print t "\t" s "\t" st }
                ' "$file"
            done
        else
            file="$HISTORY_PATH/history.jsonl"
            [[ -f "$file" ]] || return 0
            awk '
                function field(key, text, pattern, value) {
                    pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
                    if (!match(text, pattern)) return ""
                    value = substr(text, RSTART, RLENGTH)
                    sub(/^.*:[[:space:]]*"/, "", value)
                    sub(/"$/, "", value)
                    return value
                }
                { t=field("timestamp",$0); s=field("service",$0); st=field("state",$0); if (t!="" && s!="" && st!="") print t "\t" s "\t" st }
            ' "$file"
        fi
    fi
}

history_check_reader() {
    local file
    if [[ "$HISTORY_STORAGE" == sqlite ]]; then
        [[ -f "$HISTORY_PATH" ]] || return 0
        sqlite3 -readonly -batch -bail "$HISTORY_PATH" 'SELECT timestamp, service, state FROM checks LIMIT 0;' >/dev/null 2>&1 ||
            die 'history.path is not a readable history database.'
    elif [[ "$HISTORY_ROTATION_MODE" == daily ]]; then
        for file in "$HISTORY_PATH"/history_????-??-??.jsonl; do
            [[ ! -f "$file" || -r "$file" ]] || die "Cannot read history file: ${file}"
        done
    else
        file="$HISTORY_PATH/history.jsonl"
        [[ ! -f "$file" || -r "$file" ]] || die "Cannot read history file: ${file}"
    fi
}

generate_report() {
    local period="$1" cutoff now timestamp service_name state epoch percent downtime name
    local -a names=()
    local -A seen=() total=() healthy=() unavailable=() falls=() down_start=() down_seconds=() previous=()
    history_check_reader
    now="$(date '+%s')"
    case "$period" in
        daily) cutoff="$(date -d 'today 00:00:00' '+%s')" ;;
        weekly) cutoff=$((now - 7 * 86400)) ;;
        monthly) cutoff=$((now - 30 * 86400)) ;;
    esac
    while IFS=$'\t' read -r timestamp service_name state; do
        [[ -n "$timestamp" && "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
        epoch="$(date -d "$timestamp" '+%s' 2>/dev/null)" || continue
        (( epoch >= cutoff && epoch <= now )) || continue
        if [[ -z "${seen[$service_name]:-}" ]]; then seen["$service_name"]=1; names+=("$service_name"); fi
        total["$service_name"]=$(( ${total[$service_name]:-0} + 1 ))
        [[ "$state" != healthy ]] || healthy["$service_name"]=$(( ${healthy[$service_name]:-0} + 1 ))
        [[ "$state" != unavailable ]] || unavailable["$service_name"]=$(( ${unavailable[$service_name]:-0} + 1 ))
        if [[ "$state" == unavailable && -z "${down_start[$service_name]:-}" ]]; then
            [[ "${previous[$service_name]:-}" != healthy ]] || falls["$service_name"]=$(( ${falls[$service_name]:-0} + 1 ))
            down_start["$service_name"]="$epoch"
        elif [[ "$state" == healthy && -n "${down_start[$service_name]:-}" ]]; then
            down_seconds["$service_name"]=$(( ${down_seconds[$service_name]:-0} + epoch - down_start[$service_name] ))
            unset "down_start[$service_name]"
        fi
        previous["$service_name"]="$state"
    done < <(history_rows)
    printf 'SERVICE | TOTAL | HEALTHY | UNAVAILABLE | UPTIME | FALLS | DOWNTIME\n'
    for name in "${names[@]}"; do
        downtime="${down_seconds[$name]:-0}"
        if [[ -n "${down_start[$name]:-}" ]]; then downtime=$((downtime + now - down_start[$name])); fi
        percent="$(awk -v ok="${healthy[$name]:-0}" -v all="${total[$name]}" 'BEGIN { printf "%.1f%%", 100*ok/all }')"
        printf '%-25s | %5s | %7s | %11s | %6s | %5s | %s\n' "$name" "${total[$name]}" "${healthy[$name]:-0}" "${unavailable[$name]:-0}" "$percent" "${falls[$name]:-0}" "$(status_duration "$downtime")"
    done
    bootstrap_log INFO "report=${period} services=${#names[@]} period=$(date -d "@$cutoff" '+%Y-%m-%d')"
}

generate_trend() {
    local service_name="$1" row timestamp state epoch timeline='' trend_total=0 trend_healthy=0 trend_falls=0 trend_previous='' trend_down_start='' trend_down_total=0 trend_completed=0 last_fall='' last_duration='' now percent mttr
    local -a rows=()
    history_check_reader
    [[ "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'trend service must be a valid service name.'
    mapfile -t rows < <(history_rows | awk -F '\t' -v target="$service_name" '$2 == target' | tail -n "$HISTORY_TREND_DOTS")
    now="$(date '+%s')"
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r timestamp _ state <<<"$row"
        epoch="$(date -d "$timestamp" '+%s' 2>/dev/null)" || continue
        trend_total=$((trend_total + 1))
        if [[ "$state" == healthy ]]; then timeline+='█'; trend_healthy=$((trend_healthy + 1)); else timeline+='░'; fi
        if [[ "$state" == unavailable && -z "$trend_down_start" ]]; then
            [[ "$trend_previous" != healthy ]] || trend_falls=$((trend_falls + 1))
            trend_down_start="$epoch"; last_fall="$timestamp"; last_duration='ongoing'
        elif [[ "$state" == healthy && -n "$trend_down_start" ]]; then
            last_duration=$((epoch - trend_down_start))
            trend_down_total=$((trend_down_total + last_duration))
            trend_completed=$((trend_completed + 1))
            trend_down_start=''
        fi
        trend_previous="$state"
    done
    if (( trend_total == 0 )); then
        printf '%s: no history records\n' "$service_name"
        bootstrap_log INFO "trend=generated service=${service_name} dots=0 uptime=n/a"
        return 0
    fi
    percent="$(awk -v ok="$trend_healthy" -v all="$trend_total" 'BEGIN { printf "%.1f", 100*ok/all }')"
    if (( trend_completed > 0 )); then mttr="$(status_duration "$((trend_down_total / trend_completed))")"; else mttr='n/a'; fi
    if [[ -n "$trend_down_start" ]]; then last_duration=$((now - trend_down_start)); fi
    [[ "$last_duration" != '' && "$last_duration" != ongoing ]] && last_duration="$(status_duration "$last_duration")"
    [[ -n "$last_fall" ]] || last_fall='n/a'
    [[ -n "$last_duration" ]] || last_duration='n/a'
    printf '%s [%s] %s%% (%s/%s)\n' "$service_name" "$timeline" "$percent" "$trend_healthy" "$trend_total"
    printf '█ healthy  ░ unavailable/degraded/recovering\n'
    printf 'Uptime: %s%% | Falls: %s | MTTR: %s | Last fall: %s (%s)\n' "$percent" "$trend_falls" "$mttr" "$last_fall" "$last_duration"
    bootstrap_log INFO "trend=generated service=${service_name} dots=${trend_total} uptime=${percent}%"
}

notify_test_run() {
    local service_count index name found=0 channel enabled enabled_count=0 failed=0
    CURRENT_SERVICE=watchdog-test
    CURRENT_CHECK_TYPE='test'
    if [[ -n "$ONLY_SERVICE" ]]; then
        service_count="$(yaml_read '.services | length')"
        for ((index = 0; index < service_count; index++)); do
            name="$(yaml_read ".services[$index].name")"
            if [[ "$name" == "$ONLY_SERVICE" ]]; then
                CURRENT_SERVICE="$name"
                CURRENT_CHECK_TYPE="$(service_check_type "$index")"
                found=1
                break
            fi
        done
        (( found == 1 )) || die "Service not found: ${ONLY_SERVICE}"
    fi

    CHECK_DETAIL='This is a test notification from watchdog'
    CHECK_HTTP_STATUS='n/a'
    CHECK_EXIT_CODE='n/a'
    CURRENT_ACTION_STATUS='not-required'
    INCIDENT_ID="test-$(date '+%s')"
    INCIDENT_DURATION=0
    INCIDENT_REMEDIATION_RESULT='not-required'
    ESCALATION_CONSECUTIVE_UNAVAILABLE=1
    ESCALATION_COUNT=1

    mkdir -p -- "$(dirname -- "$LOG_FILE")" || die "Cannot create log directory: ${LOG_FILE}"
    touch -- "$LOG_FILE" || die "Cannot write log file: ${LOG_FILE}"
    chmod 0640 "$LOG_FILE" 2>/dev/null || true
    TEMP_DIRECTORY="$(mktemp -d)" || die 'Cannot create notification test directory.'
    if [[ -n "$ONLY_SERVICE" ]] && is_maintenance_window "$ONLY_SERVICE"; then
        bootstrap_log WARN "service=${ONLY_SERVICE} maintenance_window=${MAINTENANCE_WINDOW_NAME} result=test-notification-ignores-maintenance"
        log WARN "service=${ONLY_SERVICE} maintenance_window=${MAINTENANCE_WINDOW_NAME} result=test-notification-ignores-maintenance"
    fi

    printf 'CHANNEL | RESULT | DETAIL\n'
    for channel in email telegram discord slack ntfy pagerduty opsgenie; do
        [[ "$NOTIFY_TEST_CHANNEL" == all || "$NOTIFY_TEST_CHANNEL" == "$channel" ]] || continue
        if [[ "$channel" == email ]]; then
            enabled="$(yaml_read '.notifications.email.enabled // false')"
        else
            enabled="$(yaml_read ".notifications.webhooks.${channel}.enabled // false")"
        fi
        if [[ "$enabled" != true ]]; then
            printf '%s | skipped | disabled\n' "$channel"
            continue
        fi
        enabled_count=$((enabled_count + 1))
        NOTIFY_TEST_DETAIL=''
        if [[ "$channel" == email ]]; then
            if configure_email && send_email_notification "$NOTIFY_TEST_EVENT"; then
                printf '%s | sent | %s\n' "$channel" "$NOTIFY_TEST_DETAIL"
            else
                [[ -n "$NOTIFY_TEST_DETAIL" ]] || NOTIFY_TEST_DETAIL='delivery failed'
                printf '%s | failed | %s\n' "$channel" "$NOTIFY_TEST_DETAIL"
                failed=1
            fi
        elif send_single_webhook "$channel" "$NOTIFY_TEST_EVENT"; then
            printf '%s | sent | %s\n' "$channel" "$NOTIFY_TEST_DETAIL"
        else
            [[ -n "$NOTIFY_TEST_DETAIL" ]] || NOTIFY_TEST_DETAIL='delivery failed'
            printf '%s | failed | %s\n' "$channel" "$NOTIFY_TEST_DETAIL"
            failed=1
        fi
    done
    (( enabled_count > 0 )) || return 2
    return "$failed"
}

status_duration() {
    local seconds="$1" hours minutes
    if (( seconds < 60 )); then printf '%ss' "$seconds"; return; fi
    hours=$((seconds / 3600)); minutes=$(((seconds % 3600) / 60))
    if (( hours > 0 )); then printf '%sh%sm' "$hours" "$minutes"; else printf '%sm' "$minutes"; fi
}

status_timestamp() {
    local epoch="$1"
    if [[ "$epoch" =~ ^[0-9]{1,12}$ ]] && (( 10#$epoch > 0 )); then
        date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
    fi
    return 1
}

status_emit_service() {
    local service_name="$1" index="$2" orphaned="$3" now="$4"
    local state phase last_transition last_check since_seconds=null last_check_iso='' next_action='n/a' next_action_kind='n/a' next_seconds=null
    local circuit flapping maintenance='' escalations cooldown last_action backoff next_epoch=0 display_name since_display='-' last_display='-'
    local color_start='' color_end='' maintenance_json=null last_check_json=null

    state="$(read_state "$service_name")"
    [[ "$state" == healthy ]] || STATUS_UNHEALTHY=1
    phase="$(incident_read_field "$service_name" phase '')"
    case "$phase" in healthy|failed|degraded|recovering|blocked|flapping|unknown) ;; *) phase="$(incident_phase "$service_name" "$state")" ;; esac
    if [[ "$state" == unknown ]]; then phase=unknown
    elif flapping_is_active "$service_name"; then phase=flapping; fi
    last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
    last_check="$(read_service_marker_number "$service_name" last-check 0)"
    if [[ "$last_transition" =~ ^[0-9]{1,12}$ ]] && (( 10#$last_transition > 0 && 10#$last_transition <= now )); then
        since_seconds=$((now - 10#$last_transition))
        since_display="$(status_duration "$since_seconds")"
    fi
    if last_check_iso="$(status_timestamp "$last_check")"; then
        last_display="$last_check_iso"
        last_check_json="\"$(escape_json "$last_check_iso")\""
    fi
    circuit="$(read_service_marker_string "$service_name" circuit-state closed)"
    case "$circuit" in closed|open|half_open) ;; *) circuit=unknown ;; esac
    flapping="$(read_service_marker_string "$service_name" flapping-active false)"
    [[ "$flapping" == true ]] || flapping=false
    escalations="$(read_service_marker_number "$service_name" escalation-count 0)"
    [[ "$escalations" =~ ^[0-9]{1,12}$ ]] || escalations=0

    if (( index >= 0 )); then
        if is_maintenance_window "$service_name"; then maintenance="$MAINTENANCE_WINDOW_NAME"; fi
        if [[ "$state" != healthy && "$state" != unknown ]]; then
            next_action=ready; next_action_kind=ready
            if [[ "$(read_service_marker_string "$service_name" manual-block false)" == true ]]; then
                next_action='blocked: manual'; next_action_kind="$next_action"
            elif [[ "$circuit" == open ]]; then
                next_action='blocked: circuit-open'; next_action_kind="$next_action"
            elif [[ "$flapping" == true ]]; then
                next_action='blocked: flapping'; next_action_kind="$next_action"
            else
                cooldown="$(yaml_read ".services[$index].actions.cooldown // ${DEFAULT_ACTION_COOLDOWN}")"
                last_action="$(read_service_marker_number "$service_name" last-action 0)"
                backoff="$(read_service_marker_number "$service_name" backoff-next-attempt 0)"
                if [[ "$last_action" =~ ^[0-9]{1,12}$ ]] && (( 10#$last_action > 0 )); then
                    next_epoch=$((10#$last_action + 10#$cooldown))
                fi
                if [[ "$backoff" =~ ^[0-9]{1,12}$ ]] && (( 10#$backoff > next_epoch )); then next_epoch=$((10#$backoff)); fi
                if (( next_epoch > now )); then
                    next_seconds=$((next_epoch - now))
                    next_action="in $(status_duration "$next_seconds")"
                    next_action_kind=waiting
                fi
            fi
        fi
    fi
    display_name="$service_name"
    if [[ "$orphaned" == true ]]; then display_name+=' (orphaned)'; fi
    [[ -z "$maintenance" ]] || maintenance_json="\"$(escape_json "$maintenance")\""

    if (( STATUS_JSON == 1 )); then
        if (( STATUS_JSON_COUNT > 0 )); then printf ',\n'; fi
        printf '  {"service":"%s","state":"%s","phase":"%s","since_seconds":%s,"last_check":%s,"next_action":"%s","next_action_seconds":%s,"circuit":"%s","flapping":%s,"maintenance":%s,"escalations":%s,"orphaned":%s}' \
            "$(escape_json "$service_name")" "$state" "$(escape_json "$phase")" "$since_seconds" "$last_check_json" \
            "$(escape_json "$next_action_kind")" "$next_seconds" "$circuit" "$flapping" "$maintenance_json" "$escalations" "$orphaned"
        STATUS_JSON_COUNT=$((STATUS_JSON_COUNT + 1))
    else
        if (( STATUS_COLOR == 1 )); then
            case "$state" in healthy) color_start=$'\033[32m' ;; unavailable) color_start=$'\033[31m' ;; *) color_start=$'\033[33m' ;; esac
            color_end=$'\033[0m'
        fi
        [[ -n "$maintenance" ]] || maintenance='-'
        printf '%s | %s%s%s | %s | %s | %s | %s | %s | %s | %s | %s\n' \
            "$display_name" "$color_start" "$state" "$color_end" "$phase" "$since_display" "$last_display" \
            "$next_action" "$circuit" "$flapping" "$maintenance" "$escalations"
    fi
}

status_run() {
    local service_count index service_name state_file orphan_name now selected_found=0
    local -A configured=()
    STATUS_UNHEALTHY=0
    STATUS_JSON_COUNT=0
    STATUS_COLOR=0
    [[ -t 1 && -z "${NO_COLOR+x}" && "$STATUS_JSON" == 0 ]] && STATUS_COLOR=1
    [[ ! -e "$STATE_DIRECTORY" || ( -d "$STATE_DIRECTORY" && -r "$STATE_DIRECTORY" ) ]] ||
        die "Cannot read state directory: ${STATE_DIRECTORY}"
    now="$(date '+%s')"
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        configured["$service_name"]=1
        [[ "$service_name" != "$ONLY_SERVICE" ]] || selected_found=1
    done
    if [[ -n "$ONLY_SERVICE" && "$selected_found" == 0 ]]; then
        if (( STATUS_ALL == 0 )) || [[ ! "$ONLY_SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
            [[ ! -f "${STATE_DIRECTORY}/${ONLY_SERVICE}.state" ]]; then
            die "Service not found: ${ONLY_SERVICE}"
        fi
    fi
    if (( STATUS_JSON == 1 )); then printf '[\n'; else printf 'SERVICE | STATE | PHASE | SINCE | LAST CHECK | NEXT ACTION | CIRCUIT | FLAPPING | MAINT | ESC\n'; fi
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        [[ -z "$ONLY_SERVICE" || "$service_name" == "$ONLY_SERVICE" ]] || continue
        status_emit_service "$service_name" "$index" false "$now"
    done
    if (( STATUS_ALL == 1 )); then
        for state_file in "${STATE_DIRECTORY}/"*.state; do
            [[ -f "$state_file" ]] || continue
            orphan_name="${state_file##*/}"; orphan_name="${orphan_name%.state}"
            [[ "$orphan_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
            [[ -z "${configured[$orphan_name]:-}" ]] || continue
            [[ -z "$ONLY_SERVICE" || "$orphan_name" == "$ONLY_SERVICE" ]] || continue
            status_emit_service "$orphan_name" -1 true "$now"
        done
    fi
    if (( STATUS_JSON == 1 )); then printf '\n]\n'; fi
    return "$STATUS_UNHEALTHY"
}
