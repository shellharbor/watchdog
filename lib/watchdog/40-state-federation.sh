read_state() {
    local service_name="$1"
    local file="${STATE_DIRECTORY}/${service_name}.state" state=""
    if [[ -r "$file" ]]; then
        IFS= read -r state <"$file" || true
    fi
    case "$state" in healthy|unavailable|dependency_failed|degraded|recovering) printf '%s' "$state" ;; *) printf unknown ;; esac
}

write_state() {
    local service_name="$1" state="$2"
    local file temporary
    [[ "$(read_state "$service_name")" == "$state" ]] || FEDERATION_STATE_CHANGED=1
    file="${STATE_DIRECTORY}/${service_name}.state"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$state" >"$temporary" || die "Cannot write state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update state: ${file}"
}

incident_read_field() {
    local service_name="$1" field="$2" fallback="$3" file value=""
    file="${STATE_DIRECTORY}/${service_name}.incident.json"
    if [[ -r "$file" ]]; then
        value="$(yq eval -r ".${field}" "$file" 2>/dev/null)" || value=""
    fi
    [[ -n "$value" && "$value" != null ]] || value="$fallback"
    printf '%s' "$value"
}

incident_phase() {
    local service_name="$1" state="$2"
    if flapping_is_active "$service_name"; then printf flapping; return 0; fi
    case "$state" in
        healthy) printf healthy ;;
        degraded) printf degraded ;;
        recovering) printf recovering ;;
        unavailable) printf failed ;;
        dependency_failed) printf blocked ;;
        *) printf unknown ;;
    esac
}

incident_update() {
    local service_name="$1" state="$2" event="$3" result="${4:-}"
    local now file temporary history history_tmp active id started changed attempts duration phase blocked_by line old_active
    (( DRY_RUN == 0 )) || return 0
    now="$(date '+%s')"
    file="${STATE_DIRECTORY}/${service_name}.incident.json"
    active="$(incident_read_field "$service_name" active false)"
    old_active="$active"
    id="$(incident_read_field "$service_name" id "")"
    started="$(incident_read_field "$service_name" started_at 0)"
    changed="$(incident_read_field "$service_name" last_changed_at 0)"
    attempts="$(incident_read_field "$service_name" attempts 0)"
    INCIDENT_REMEDIATION_RESULT="$(incident_read_field "$service_name" remediation_result not-attempted)"
    if [[ "$state" == unavailable || "$state" == degraded || "$state" == recovering || "$state" == dependency_failed ]]; then
        if [[ "$active" != true ]]; then
            active=true
            id="${service_name}-${now}-${RANDOM}"
            started="$(read_service_marker_number "$service_name" last-transition 0)"
            (( 10#$started > 0 && 10#$started <= now )) || started="$now"
            attempts=0
            INCIDENT_REMEDIATION_RESULT=not-attempted
            increment_service_marker_number "$service_name" incidents-total
        fi
    elif [[ "$state" == healthy ]]; then
        active=false
    fi
    if [[ "$event" == attempt ]]; then attempts=$((10#$attempts + 1)); fi
    [[ -z "$result" ]] || INCIDENT_REMEDIATION_RESULT="$result"
    if [[ "$event" == transition || "$event" == attempt || "$event" == result || "$event" == blocked ]]; then changed="$now"; fi
    duration=0
    if (( 10#$started > 0 && now >= 10#$started )); then duration=$((now - 10#$started)); fi
    phase="$(incident_phase "$service_name" "$state")"
    blocked_by="$(read_service_marker_string "$service_name" blocked-by "")"
    line="$(printf '{"schema_version":1,"active":%s,"id":"%s","state":"%s","phase":"%s","started_at":%s,"last_changed_at":%s,"attempts":%s,"remediation_result":"%s","duration_seconds":%s,"blocked_by":"%s"}' \
        "$active" "$(escape_json "$id")" "$(escape_json "$state")" "$(escape_json "$phase")" "$started" "$changed" "$attempts" \
        "$(escape_json "$INCIDENT_REMEDIATION_RESULT")" "$duration" "$(escape_json "$blocked_by")")"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$line" >"$temporary" || die "Cannot write incident state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update incident state: ${file}"
    INCIDENT_ID="$id"
    INCIDENT_DURATION="$duration"
    if [[ "$old_active" == true && "$active" == false ]]; then
        write_service_marker_number "$service_name" incident-last-duration "$duration"
        history="${STATE_DIRECTORY}/${service_name}.incident-history.jsonl"
        history_tmp="${history}.tmp.$$"
        if [[ -r "$history" ]]; then
            tail -n 99 -- "$history" >"$history_tmp" || die "Cannot read incident history: ${history}"
        else
            : >"$history_tmp" || die "Cannot create incident history: ${history_tmp}"
        fi
        printf '%s\n' "$line" >>"$history_tmp" || die "Cannot write incident history: ${history_tmp}"
        chmod 0640 "$history_tmp" 2>/dev/null || true
        mv -f -- "$history_tmp" "$history" || die "Cannot update incident history: ${history}"
        log INFO "service=${service_name} incident=${id} result=recovered duration_seconds=${duration} remediation=${INCIDENT_REMEDIATION_RESULT}"
    fi
}

format_federation_timestamp() {
    local epoch="$1"
    if ! [[ "$epoch" =~ ^[0-9]+$ ]] || (( 10#$epoch == 0 )); then
        printf ''
        return 0
    fi
    date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
}

federation_agent_overall_status() {
    local service_count index service_name state has_degraded=0
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        state="$(read_state "$service_name")"
        [[ "$state" == unavailable ]] && { printf 'major_outage'; return 0; }
        [[ "$state" == dependency_failed || "$state" == unknown || "$state" == degraded || "$state" == recovering ]] && has_degraded=1
    done
    if (( has_degraded == 1 )); then
        printf 'degraded'
    else
        printf 'operational'
    fi
}

federation_agent_build_report() {
    local service_count index service_name check_type state last_check last_transition overall hostname_value
    service_count="$(yaml_read '.services | length')"
    overall="$(federation_agent_overall_status)"
    hostname_value="$(hostname 2>/dev/null || hostname -s)"
    printf '{\n  "node_id": "%s",\n  "timestamp": "%s",\n  "hostname": "%s",\n' \
        "$(escape_json "$FEDERATION_NODE_ID")" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(escape_json "$hostname_value")"
    printf '  "watchdog_version": "%s",\n  "overall_status": "%s",\n  "services": [\n' \
        "$(escape_json "$WATCHDOG_VERSION")" "$overall"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        check_type="$(service_check_type "$index")"
        state="$(read_state "$service_name")"
        last_check="$(read_service_marker_number "$service_name" last-check 0)"
        last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
        printf '    {"name":"%s","state":"%s","check_type":"%s","last_check":"%s","last_transition":"%s","detail":""}%s\n' \
            "$(escape_json "$service_name")" "$state" "$(escape_json "$check_type")" \
            "$(format_federation_timestamp "$last_check")" "$(format_federation_timestamp "$last_transition")" \
            "$([[ $index -lt $((service_count - 1)) ]] && printf ',')"
    done
    printf '  ]\n}\n'
}

federation_agent_should_report() {
    local service_count index service_name state overall marker previous=""
    (( FEDERATION_AGENT_HEARTBEAT == 1 )) && return 0
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        state="$(read_state "$service_name")"
        [[ "$state" == unavailable || "$state" == dependency_failed ]] && return 0
    done
    marker="${STATE_DIRECTORY}/federation-last-report-overall"
    if [[ -r "$marker" ]]; then
        IFS= read -r previous <"$marker" || true
    fi
    overall="$(federation_agent_overall_status)"
    [[ -z "$previous" || "$previous" != "$overall" || "$FEDERATION_STATE_CHANGED" == 1 ]]
}

federation_agent_record_report() {
    local overall="$1" file temporary
    file="${STATE_DIRECTORY}/federation-last-report-overall"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$overall" >"$temporary" || return 1
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file"
}

federation_agent_send_report() {
    local report report_file response_file error_file http_status curl_status token="" result duration_start duration_end
    local overall bytes temporary
    local -a curl_command

    (( FEDERATION_AGENT_ENABLED == 1 )) || return 0
    if (( DRY_RUN == 1 )); then
        log INFO "federation=agent node=${FEDERATION_NODE_ID} result=skipped reason=dry_run"
        return 0
    fi
    if ! federation_agent_should_report; then
        log INFO "federation=agent node=${FEDERATION_NODE_ID} result=skipped reason=heartbeat_disabled all_healthy=true"
        return 0
    fi
    report="$(federation_agent_build_report)"
    overall="$(federation_agent_overall_status)"
    bytes="${#report}"
    duration_start="$(now_milliseconds)"
    if [[ "$FEDERATION_AGENT_TRANSPORT" == file ]]; then
        if ! mkdir -p -- "$(dirname -- "$FEDERATION_AGENT_REPORT_PATH")" 2>/dev/null; then
            log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=file result=failed reason=directory path=${FEDERATION_AGENT_REPORT_PATH}"
            return 0
        fi
        temporary="${FEDERATION_AGENT_REPORT_PATH}.tmp.$$"
        if printf '%s\n' "$report" >"$temporary" && chmod 0640 "$temporary" 2>/dev/null && mv -f -- "$temporary" "$FEDERATION_AGENT_REPORT_PATH"; then
            federation_agent_record_report "$overall" || log WARN "federation=agent node=${FEDERATION_NODE_ID} result=marker-write-failed"
            log INFO "federation=agent node=${FEDERATION_NODE_ID} transport=file result=written path=${FEDERATION_AGENT_REPORT_PATH} bytes=${bytes}"
        else
            rm -f -- "$temporary"
            log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=file result=failed path=${FEDERATION_AGENT_REPORT_PATH}"
        fi
        return 0
    fi

    token="${!FEDERATION_AGENT_TOKEN_ENV:-}"
    if [[ -z "$token" ]]; then
        log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=http result=failed reason=missing-env:${FEDERATION_AGENT_TOKEN_ENV}"
        return 0
    fi
    report_file="${TEMP_DIRECTORY}/federation-report.json"
    response_file="${TEMP_DIRECTORY}/federation-response.txt"
    error_file="${TEMP_DIRECTORY}/federation-error.txt"
    printf '%s\n' "$report" >"$report_file"
    curl_command=(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --request POST
        --header 'Content-Type: application/json' --header "Authorization: Bearer ${token}"
        --connect-timeout "$FEDERATION_AGENT_TIMEOUT" --max-time "$FEDERATION_AGENT_TIMEOUT")
    http_status="$("${curl_command[@]}" --data-binary "@${report_file}" "$FEDERATION_AGENT_HUB_URL" 2>"$error_file")"
    curl_status=$?
    duration_end="$(now_milliseconds)"
    if (( curl_status == 0 )) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        federation_agent_record_report "$overall" || log WARN "federation=agent node=${FEDERATION_NODE_ID} result=marker-write-failed"
        log INFO "federation=agent node=${FEDERATION_NODE_ID} transport=http result=sent bytes=${bytes} duration_ms=$((duration_end - duration_start)) status=${http_status}"
    else
        result=""
        [[ -s "$error_file" ]] && result="$(sanitize_detail "$(<"$error_file")")"
        [[ -n "$result" || ! -s "$response_file" ]] || result="$(sanitize_detail "$(<"$response_file")")"
        log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=http result=failed status=${http_status:-000} curl_exit=${curl_status} error=${result:-unknown}"
    fi
}

federation_hub_state_value() {
    local node_id="$1" field="$2" fallback="$3" value=""
    [[ -r "$FEDERATION_HUB_STATE_FILE" ]] || { printf '%s' "$fallback"; return 0; }
    value="$(yq eval -r ".agents.\"${node_id}\".${field} // \"\"" "$FEDERATION_HUB_STATE_FILE" 2>/dev/null)" || value=""
    [[ -n "$value" && "$value" != null ]] || value="$fallback"
    printf '%s' "$value"
}

federation_hub_render_template() {
    local template="$1" overall="$2" previous="$3" timestamp="$4" node_id="$5" age="$6"
    template="${template//\{\{overall_status\}\}/$overall}"
    template="${template//\{\{previous_status\}\}/$previous}"
    template="${template//\{\{timestamp\}\}/$timestamp}"
    template="${template//\{\{node_id\}\}/$node_id}"
    template="${template//\{\{age_seconds\}\}/$age}"
    template="${template//\{\{unhealthy_services\}\}/$FEDERATION_HUB_UNHEALTHY_SERVICES}"
    template="${template//\{\{offline_nodes\}\}/$FEDERATION_HUB_OFFLINE_NODES}"
    template="${template//\{\{#unhealthy_services\}\}/}"
    template="${template//\{\{/unhealthy_services\}\}/}"
    template="${template//\{\{#offline_nodes\}\}/}"
    template="${template//\{\{/offline_nodes\}\}/}"
    printf '%s' "$template"
}

federation_hub_notify() {
    local event="$1" overall="$2" previous="$3" node_id="${4:-}" age="${5:-0}"
    local subject_template body_template subject body timestamp webhook_event
    case "$event" in
        overall_failure)
            subject_template='[FEDERATION] Infrastructure status: {{overall_status}}'
            body_template=$'Overall status changed to {{overall_status}}.\n\nUnhealthy services:\n{{unhealthy_services}}\nOffline agents:\n{{offline_nodes}}'
            webhook_event=failure
            ;;
        overall_recovery)
            subject_template='[FEDERATION] Infrastructure recovered: {{overall_status}}'
            body_template='All services are operational. Previously: {{previous_status}}'
            webhook_event=recovery
            ;;
        agent_offline)
            subject_template='[FEDERATION] Agent {{node_id}} is offline'
            body_template='Agent {{node_id}} has not reported for {{age_seconds}} seconds.'
            webhook_event=failure
            ;;
        agent_online)
            subject_template='[FEDERATION] Agent {{node_id}} is online'
            body_template='Agent {{node_id}} is reporting again.'
            webhook_event=recovery
            ;;
        service_change)
            subject_template='[FEDERATION] Service state change on {{node_id}}'
            body_template=$'A service state changed on {{node_id}}.\n\nUnhealthy services:\n{{unhealthy_services}}'
            webhook_event=failure
            ;;
        *) return 1 ;;
    esac
    [[ "$(yaml_read ".federation.hub.templates.${event}.subject // \"\"")" == "" ]] || subject_template="$(yaml_read ".federation.hub.templates.${event}.subject")"
    [[ "$(yaml_read ".federation.hub.templates.${event}.body // \"\"")" == "" ]] || body_template="$(yaml_read ".federation.hub.templates.${event}.body")"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    subject="$(federation_hub_render_template "$subject_template" "$overall" "$previous" "$timestamp" "$node_id" "$age")"
    body="$(federation_hub_render_template "$body_template" "$overall" "$previous" "$timestamp" "$node_id" "$age")"
    CURRENT_SERVICE="federation"; CURRENT_CHECK_TYPE="federation"; CURRENT_ACTION_STATUS="not-applicable"; CHECK_DETAIL="$body"
    send_email_message "$event" "$subject" "$body" || log ERROR "federation=hub result=email-failed event=${event}"
    send_webhook_notification "$webhook_event" || log ERROR "federation=hub result=webhook-failed event=${event}"
}

federation_hub_write_state() {
    local overall="$1" status_name="$2" seen_name="$3" fingerprint_name="$4"
    local -n status_ref="$status_name" seen_ref="$seen_name" fingerprint_ref="$fingerprint_name"
    local temporary node_id comma=""
    temporary="${FEDERATION_HUB_STATE_FILE}.tmp.$$"
    {
        printf '{\n  "last_run": "%s",\n  "last_overall_status": "%s",\n  "agents": {' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$overall"
        for node_id in "${!status_ref[@]}"; do
            printf '%s\n    "%s": {"last_seen":"%s","last_status":"%s","service_fingerprint":"%s"}' \
                "$comma" "$(escape_json "$node_id")" "$(escape_json "${seen_ref[$node_id]:-}")" \
                "$(escape_json "${status_ref[$node_id]}")" "$(escape_json "${fingerprint_ref[$node_id]:-}")"
            comma=,
        done
        printf '\n  }\n}\n'
    } >"$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$FEDERATION_HUB_STATE_FILE"
}

federation_hub_generate_summary() {
    if [[ -z "$FEDERATION_HUB_UNHEALTHY_SERVICES" ]]; then
        FEDERATION_HUB_UNHEALTHY_SERVICES='- none'
    fi
    if [[ -z "$FEDERATION_HUB_OFFLINE_NODES" ]]; then
        FEDERATION_HUB_OFFLINE_NODES='- none'
    fi
}

# shellcheck disable=SC2034 # The maps below are consumed through namerefs by federation_hub_write_state.
federation_hub_process_reports() {
    local report_file node_id json_node timestamp timestamp_epoch now age service_count service_index service_name service_state last_transition
    local reports_processed=0 valid_reports=0 invalid_reports=0 fresh_reports=0 moved=0 deleted=0 previous_overall overall
    local expected_count expected_index expected_node previous_agent_status previous_fingerprint fingerprint stale_seen stale_epoch
    local has_degraded=0 has_unavailable=0 archive_target
    local -a valid_files=() expected_nodes=()
    local -A selected_file=() selected_epoch=() selected_timestamp=() file_node=() fresh_status=() fresh_fingerprint=()
    local -A agent_status=() agent_seen=() agent_fingerprint=()

    if (( DRY_RUN == 0 )) && ! mkdir -p -- "$FEDERATION_HUB_INCOMING_DIRECTORY" "$FEDERATION_HUB_ARCHIVE_DIRECTORY" 2>/dev/null; then
        log ERROR "federation=hub result=failed reason=directory"
        FEDERATION_HUB_OVERALL_STATUS=unknown
        return 0
    fi
    now="$(date '+%s')"
    for report_file in "$FEDERATION_HUB_INCOMING_DIRECTORY"/*.json; do
        [[ -f "$report_file" ]] || continue
        ((reports_processed++))
        node_id="${report_file##*/}"; node_id="${node_id%.json}"
        if ! [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ! yq eval -e '.' "$report_file" >/dev/null 2>&1; then
            ((invalid_reports++)); log WARN "federation=hub file=${report_file} result=invalid"; continue
        fi
        json_node="$(yq eval -r '.node_id // ""' "$report_file" 2>/dev/null)"
        timestamp="$(yq eval -r '.timestamp // ""' "$report_file" 2>/dev/null)"
        if [[ "$json_node" != "$node_id" ]] || ! timestamp_epoch="$(date -u -d "$timestamp" '+%s' 2>/dev/null)" || ! [[ "$timestamp_epoch" =~ ^[0-9]+$ ]] || [[ "$(yq eval -r '.services | type' "$report_file" 2>/dev/null)" != '!!seq' ]]; then
            ((invalid_reports++)); log WARN "federation=hub node=${node_id} result=invalid"; continue
        fi
        ((valid_reports++)); valid_files+=("$report_file"); file_node["$report_file"]="$node_id"
        if [[ -z "${selected_epoch[$node_id]:-}" ]] || (( 10#$timestamp_epoch > 10#${selected_epoch[$node_id]} )); then
            selected_file["$node_id"]="$report_file"; selected_epoch["$node_id"]="$timestamp_epoch"; selected_timestamp["$node_id"]="$timestamp"
        fi
    done

    FEDERATION_HUB_UNHEALTHY_SERVICES=""; FEDERATION_HUB_OFFLINE_NODES=""
    for node_id in "${!selected_file[@]}"; do
        report_file="${selected_file[$node_id]}"; timestamp_epoch="${selected_epoch[$node_id]}"; timestamp="${selected_timestamp[$node_id]}"
        age=$((now - 10#$timestamp_epoch)); (( age < 0 )) && age=0
        if (( age > FEDERATION_HUB_MAX_REPORT_AGE )); then
            log WARN "federation=hub node=${node_id} result=offline age=${age}s max_age=${FEDERATION_HUB_MAX_REPORT_AGE}s"
            continue
        fi
        ((fresh_reports++)); service_count="$(yq eval '.services | length' "$report_file")"; fingerprint=""
        fresh_status["$node_id"]=operational
        for ((service_index = 0; service_index < service_count; service_index++)); do
            service_name="$(yq eval -r ".services[$service_index].name // \"unnamed-${service_index}\"" "$report_file")"
            service_state="$(yq eval -r ".services[$service_index].state // \"unknown\"" "$report_file")"
            last_transition="$(yq eval -r ".services[$service_index].last_transition // \"unknown\"" "$report_file")"
            case "$service_state" in healthy|unavailable|dependency_failed|degraded|recovering|unknown) ;; *) service_state=unknown ;; esac
            fingerprint+="${service_name}:${service_state};"
            if [[ "$service_state" == unavailable ]]; then
                fresh_status["$node_id"]=major_outage; has_unavailable=1
            elif [[ "$service_state" != healthy && "${fresh_status[$node_id]}" != major_outage ]]; then
                fresh_status["$node_id"]=degraded; has_degraded=1
            fi
            [[ "$service_state" == healthy ]] || FEDERATION_HUB_UNHEALTHY_SERVICES+="- [${node_id}] ${service_name}: ${service_state} (since ${last_transition})"$'\n'
        done
        fresh_fingerprint["$node_id"]="$fingerprint"; agent_status["$node_id"]="${fresh_status[$node_id]}"; agent_seen["$node_id"]="$timestamp"; agent_fingerprint["$node_id"]="$fingerprint"
        log INFO "federation=hub node=${node_id} result=online status=${fresh_status[$node_id]}"
    done

    expected_count="$(yaml_read '.federation.hub.expected_nodes // [] | length')"
    for ((expected_index = 0; expected_index < expected_count; expected_index++)); do expected_nodes+=("$(yaml_read ".federation.hub.expected_nodes[$expected_index]")"); done
    previous_overall=unknown
    [[ -r "$FEDERATION_HUB_STATE_FILE" ]] && previous_overall="$(yq eval -r '.last_overall_status // "unknown"' "$FEDERATION_HUB_STATE_FILE" 2>/dev/null || printf unknown)"
    for expected_node in "${expected_nodes[@]}"; do
        previous_agent_status="$(federation_hub_state_value "$expected_node" last_status unknown)"
        if [[ -n "${fresh_status[$expected_node]:-}" ]]; then
            if [[ "$previous_agent_status" == offline ]]; then
                log INFO "federation=hub node=${expected_node} result=online action=recovered"
                if [[ "$(yaml_read_true_default '.federation.hub.notify_on.agent_offline')" == true && "$DRY_RUN" == 0 ]]; then
                    federation_hub_notify agent_online "${fresh_status[$expected_node]}" "$previous_overall" "$expected_node" 0
                fi
            fi
            continue
        fi
        stale_seen="${selected_timestamp[$expected_node]:-$(federation_hub_state_value "$expected_node" last_seen unknown)}"
        stale_epoch="${selected_epoch[$expected_node]:-0}"
        if [[ "$stale_epoch" =~ ^[0-9]+$ ]] && (( 10#$stale_epoch > 0 )); then age=$((now - 10#$stale_epoch)); (( age < 0 )) && age=0; else age=$((FEDERATION_HUB_MAX_REPORT_AGE + 1)); fi
        agent_status["$expected_node"]=offline; agent_seen["$expected_node"]="$stale_seen"; agent_fingerprint["$expected_node"]=""
        FEDERATION_HUB_OFFLINE_NODES+="- ${expected_node} (last seen ${stale_seen})"$'\n'
        if [[ "$previous_agent_status" != offline ]]; then
            log WARN "federation=hub notify=agent_offline node=${expected_node} age=${age}s"
            if [[ "$(yaml_read_true_default '.federation.hub.notify_on.agent_offline')" == true && "$DRY_RUN" == 0 ]]; then
                federation_hub_notify agent_offline degraded "$previous_overall" "$expected_node" "$age"
            fi
        fi
    done

    if (( fresh_reports == 0 )); then overall=unknown
    elif (( has_unavailable == 1 )); then overall=major_outage
    elif (( has_degraded == 1 )); then overall=degraded
    else overall=operational; fi
    # Offline expected agents also make the infrastructure degraded, even when
    # every fresh report is healthy.
    [[ -z "$FEDERATION_HUB_OFFLINE_NODES" || "$overall" != operational ]] || overall=degraded
    FEDERATION_HUB_OVERALL_STATUS="$overall"
    federation_hub_generate_summary
    if [[ "$previous_overall" != "$overall" ]]; then
        if [[ "$(yaml_read_true_default '.federation.hub.notify_on.overall_change')" == true && "$DRY_RUN" == 0 && ! ( "$previous_overall" == unknown && "$overall" == operational ) ]]; then
            if [[ "$overall" == operational ]]; then federation_hub_notify overall_recovery "$overall" "$previous_overall"; else federation_hub_notify overall_failure "$overall" "$previous_overall"; fi
            log INFO "federation=hub overall_status=${overall} previous=${previous_overall} action=notify"
        else
            log INFO "federation=hub overall_status=${overall} previous=${previous_overall} action=record"
        fi
    fi
    if [[ "$(yaml_read '.federation.hub.notify_on.any_service_change // false')" == true && "$DRY_RUN" == 0 ]]; then
        for node_id in "${!fresh_fingerprint[@]}"; do
            previous_fingerprint="$(federation_hub_state_value "$node_id" service_fingerprint "")"
            if [[ -n "$previous_fingerprint" && "$previous_fingerprint" != "${fresh_fingerprint[$node_id]}" && "$previous_overall" == "$overall" ]]; then
                log INFO "federation=hub notify=service_change node=${node_id}"
                federation_hub_notify service_change "$overall" "$previous_overall" "$node_id"
            fi
        done
    fi
    if (( DRY_RUN == 0 )); then
        federation_hub_write_state "$overall" agent_status agent_seen agent_fingerprint || log ERROR "federation=hub result=state-write-failed"
        for report_file in "${valid_files[@]}"; do
            node_id="${file_node[$report_file]}"; timestamp="$(yq eval -r '.timestamp' "$report_file")"
            archive_target="${FEDERATION_HUB_ARCHIVE_DIRECTORY}/${node_id}_${timestamp}.json"
            [[ ! -e "$archive_target" ]] || archive_target="${FEDERATION_HUB_ARCHIVE_DIRECTORY}/${node_id}_${timestamp}.$$.json"
            if mv -f -- "$report_file" "$archive_target"; then ((moved++)); else log ERROR "federation=hub archive=failed file=${report_file}"; fi
        done
        if (( FEDERATION_HUB_ARCHIVE_RETENTION_DAYS > 0 )); then
            deleted="$(find "$FEDERATION_HUB_ARCHIVE_DIRECTORY" -type f -name '*.json' -mtime "+${FEDERATION_HUB_ARCHIVE_RETENTION_DAYS}" -print 2>/dev/null | awk 'END { print NR }')"
            find "$FEDERATION_HUB_ARCHIVE_DIRECTORY" -type f -name '*.json' -mtime "+${FEDERATION_HUB_ARCHIVE_RETENTION_DAYS}" -delete 2>/dev/null || log ERROR "federation=hub archive=retention-failed"
        fi
    fi
    log INFO "federation=hub reports_processed=${reports_processed} valid=${valid_reports} invalid=${invalid_reports}"
    log INFO "federation=hub archive=done moved=${moved} deleted_old=${deleted}"
}

