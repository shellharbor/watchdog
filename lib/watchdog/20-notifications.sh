sanitize_detail() {
    printf '%s' "$1" | tail -c 4096 | tr '\r\n' '  '
}

apply_condition_invert() {
    local index="$1" condition="$2" raw_result="$3" invert
    invert="$(yaml_read ".services[$index].only_if[$condition].invert // false")"
    if [[ "$invert" == true ]]; then
        CONDITION_DETAIL+=" invert=true"
        if (( raw_result == 0 )); then
            return 1
        fi
        return 0
    fi
    return "$raw_result"
}

condition_expected_exit_matches() {
    local index="$1" condition="$2" exit_code="$3" value_type expected count item
    value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code | type")"
    if [[ "$value_type" == "!!null" ]]; then
        [[ "$exit_code" == 0 ]]
        return
    fi
    if [[ "$value_type" == "!!int" ]]; then
        expected="$(yaml_read ".services[$index].only_if[$condition].exit_code")"
        [[ "$exit_code" == "$expected" ]]
        return
    fi
    count="$(yaml_read ".services[$index].only_if[$condition].exit_code | length")"
    for ((item = 0; item < count; item++)); do
        expected="$(yaml_read ".services[$index].only_if[$condition].exit_code[$item]")"
        [[ "$exit_code" == "$expected" ]] && return 0
    done
    return 1
}

condition_expected_exit_description() {
    local index="$1" condition="$2" value_type count item result=""
    value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code | type")"
    [[ "$value_type" == "!!null" ]] && { printf '0'; return; }
    [[ "$value_type" == "!!int" ]] && { yaml_read ".services[$index].only_if[$condition].exit_code"; return; }
    count="$(yaml_read ".services[$index].only_if[$condition].exit_code | length")"
    for ((item = 0; item < count; item++)); do
        if [[ -n "$result" ]]; then
            result+=","
        fi
        result+="$(yaml_read ".services[$index].only_if[$condition].exit_code[$item]")"
    done
    printf '[%s]' "$result"
}

read_filesystem_usage() {
    local path="$1" timeout_value="${2:-$DEFAULT_TIMEOUT}" df_values total_bytes free_bytes
    df_values="$(LC_ALL=C timeout --signal=TERM --kill-after=2s "$timeout_value" \
        df -B1 --output=size,avail -- "$path" 2>/dev/null |
        LC_ALL=C awk 'NR == 2 { print $1, $2 }')" || return 1
    IFS=' ' read -r total_bytes free_bytes <<<"$df_values"
    [[ "$total_bytes" =~ ^[0-9]+$ && "$free_bytes" =~ ^[0-9]+$ ]] || return 1
    (( 10#$total_bytes > 0 && 10#$free_bytes <= 10#$total_bytes )) || return 1
    FILESYSTEM_TOTAL_BYTES="$total_bytes"
    FILESYSTEM_FREE_BYTES="$free_bytes"
    FILESYSTEM_FREE_PERCENT="$(LC_ALL=C awk -v free="$free_bytes" -v total="$total_bytes" \
        'BEGIN { printf "%.2f", free * 100 / total }')"
    FILESYSTEM_FREE_GB="$(LC_ALL=C awk -v free="$free_bytes" \
        'BEGIN { printf "%.2f", free / 1073741824 }')"
}

evaluate_single_condition() {
    local index="$1" condition="$2" type raw_result=1 timeout_value command_status formatted
    local path days time timezone day now start end normalized_day matched_day
    local load_1 load_5 load_15 field threshold current value_type
    local min_free_gb min_free_percent
    local -a condition_command=() condition_days=()

    CONDITION_DETAIL=""
    CONDITION_ERROR=0
    type="$(yaml_read ".services[$index].only_if[$condition].type")"
    case "$type" in
        command)
            load_command ".services[$index].only_if[$condition].command" condition_command
            formatted="$(format_command condition_command)"
            timeout_value="$(yaml_read ".services[$index].only_if[$condition].timeout // 10")"
            timeout --signal=TERM --kill-after=2s "$timeout_value" "${condition_command[@]}" >/dev/null 2>&1
            command_status=$?
            if (( command_status == 124 || command_status == 137 )); then
                CONDITION_ERROR=1
                CONDITION_DETAIL="command ${formatted} reason=timeout"
            else
                CONDITION_DETAIL="command ${formatted} exit=${command_status} expected=$(condition_expected_exit_description "$index" "$condition")"
                condition_expected_exit_matches "$index" "$condition" "$command_status" && raw_result=0
            fi
            ;;
        file_exists)
            path="$(yaml_read ".services[$index].only_if[$condition].path")"
            CONDITION_DETAIL="file_exists path=${path}"
            [[ -e "$path" ]] && raw_result=0
            ;;
        time_window)
            days="$(yaml_read ".services[$index].only_if[$condition].days")"
            time="$(yaml_read ".services[$index].only_if[$condition].time")"
            timezone="$(yaml_read ".services[$index].only_if[$condition].timezone // \"\"")"
            if [[ -n "$timezone" ]]; then
                day="$(TZ="$timezone" LC_ALL=C date '+%a')"
                now="$(TZ="$timezone" date '+%H:%M')"
            else
                day="$(LC_ALL=C date '+%a')"
                now="$(date '+%H:%M')"
            fi
            day="${day,,}"
            matched_day=0
            if [[ "$days" == "*" ]]; then
                matched_day=1
            else
                IFS=',' read -r -a condition_days <<<"$days"
                for normalized_day in "${condition_days[@]}"; do
                    [[ "${normalized_day,,}" == "$day" ]] && matched_day=1
                done
            fi
            start="${time%-*}"; end="${time#*-}"
            CONDITION_DETAIL="time_window days=${days} time=${time} current=${day}_${now}${timezone:+ timezone=${timezone}}"
            if (( matched_day == 1 )) && [[ "$now" > "$start" || "$now" == "$start" ]] && [[ "$now" < "$end" ]]; then
                raw_result=0
            fi
            ;;
        load_average)
            if [[ ! -r /proc/loadavg ]] || ! read -r load_1 load_5 load_15 _ </proc/loadavg; then
                CONDITION_ERROR=1
                CONDITION_DETAIL="load_average reason=unavailable"
                apply_condition_invert "$index" "$condition" "$raw_result"
                return
            fi
            raw_result=0
            for field in max_1min max_5min max_15min; do
                value_type="$(yaml_read ".services[$index].only_if[$condition].${field} | type")"
                [[ "$value_type" == "!!null" ]] && continue
                threshold="$(yaml_read ".services[$index].only_if[$condition].${field}")"
                case "$field" in max_1min) current="$load_1" ;; max_5min) current="$load_5" ;; *) current="$load_15" ;; esac
                if ! awk -v current="$current" -v maximum="$threshold" 'BEGIN { exit !(current <= maximum) }'; then
                    raw_result=1
                    CONDITION_DETAIL="load_average ${field}=${threshold} current=${current}"
                    break
                fi
                CONDITION_DETAIL="load_average ${field}=${threshold} current=${current}"
            done
            ;;
        filesystem)
            path="$(yaml_read ".services[$index].only_if[$condition].path")"
            if ! read_filesystem_usage "$path" "$DEFAULT_TIMEOUT"; then
                CONDITION_ERROR=1
                CONDITION_DETAIL="filesystem path=${path} reason=unavailable"
                apply_condition_invert "$index" "$condition" "$raw_result"
                return
            fi
            raw_result=0
            value_type="$(yaml_read ".services[$index].only_if[$condition].min_free_gb | type")"
            if [[ "$value_type" != "!!null" ]]; then
                min_free_gb="$(yaml_read ".services[$index].only_if[$condition].min_free_gb")"
                if ! LC_ALL=C awk -v bytes="$FILESYSTEM_FREE_BYTES" -v minimum="$min_free_gb" \
                    'BEGIN { exit !(bytes >= minimum * 1073741824) }'; then
                    raw_result=1
                    CONDITION_DETAIL="filesystem path=${path} min_free_gb=${min_free_gb} current_free_gb=${FILESYSTEM_FREE_GB}"
                fi
            fi
            value_type="$(yaml_read ".services[$index].only_if[$condition].min_free_percent | type")"
            if [[ "$value_type" != "!!null" ]] && (( raw_result == 0 )); then
                min_free_percent="$(yaml_read ".services[$index].only_if[$condition].min_free_percent")"
                if ! LC_ALL=C awk -v free="$FILESYSTEM_FREE_BYTES" -v total="$FILESYSTEM_TOTAL_BYTES" \
                    -v minimum="$min_free_percent" 'BEGIN { exit !(free * 100 / total >= minimum) }'; then
                    raw_result=1
                    CONDITION_DETAIL="filesystem path=${path} min_free_percent=${min_free_percent} current_free_percent=${FILESYSTEM_FREE_PERCENT}"
                fi
            fi
            [[ -n "$CONDITION_DETAIL" ]] || CONDITION_DETAIL="filesystem path=${path} current_free_percent=${FILESYSTEM_FREE_PERCENT}"
            ;;
        *)
            CONDITION_ERROR=1
            CONDITION_DETAIL="condition type=${type} reason=unsupported"
            ;;
    esac
    apply_condition_invert "$index" "$condition" "$raw_result"
}

evaluate_conditions() {
    local index="$1" service_name="$2" count condition
    count="$(yaml_read ".services[$index].only_if // [] | length")"
    (( count > 0 )) || return 0
    for ((condition = 0; condition < count; condition++)); do
        if evaluate_single_condition "$index" "$condition"; then
            continue
        fi
        if (( CONDITION_ERROR == 1 )); then
            log WARN "service=${service_name} only_if=error condition=\"$(sanitize_detail "$CONDITION_DETAIL")\" condition_index=$((condition + 1)) action=skipped"
        else
            log INFO "service=${service_name} only_if=false condition=\"$(sanitize_detail "$CONDITION_DETAIL")\" condition_index=$((condition + 1)) action=skipped"
        fi
        return 1
    done
    log INFO "service=${service_name} only_if=true conditions=${count}"
    return 0
}

render_email_template() {
    local template="$1"
    local event="$2"
    local timestamp="$3"
    local detail node_id
    detail="$(sanitize_detail "$CHECK_DETAIL")"
    node_id="$(yaml_read '.federation.node_id // ""')"
    [[ -n "$node_id" ]] || node_id="$(hostname -s)"

    template="${template//\{\{service\}\}/$CURRENT_SERVICE}"
    template="${template//\{\{event\}\}/$event}"
    template="${template//\{\{timestamp\}\}/$timestamp}"
    template="${template//\{\{check_type\}\}/$CURRENT_CHECK_TYPE}"
    template="${template//\{\{detail\}\}/$detail}"
    template="${template//\{\{node_id\}\}/$node_id}"
    template="${template//\{\{match_count\}\}/${MATCH_COUNT:-n/a}}"
    template="${template//\{\{threshold\}\}/${THRESHOLD_VALUE:-n/a}}"
    template="${template//\{\{comparator\}\}/${THRESHOLD_COMPARATOR:-n/a}}"
    template="${template//\{\{since\}\}/${THRESHOLD_SINCE:-n/a}}"
    template="${template//\{\{http_status\}\}/${CHECK_HTTP_STATUS:-n/a}}"
    template="${template//\{\{check_exit\}\}/${CHECK_EXIT_CODE:-n/a}}"
    template="${template//\{\{action_status\}\}/$CURRENT_ACTION_STATUS}"
    template="${template//\{\{consecutive_unavailable\}\}/$ESCALATION_CONSECUTIVE_UNAVAILABLE}"
    template="${template//\{\{escalation_count\}\}/$ESCALATION_COUNT}"
    template="${template//\{\{incident_id\}\}/$INCIDENT_ID}"
    template="${template//\{\{incident_duration_seconds\}\}/$INCIDENT_DURATION}"
    template="${template//\{\{remediation_result\}\}/$INCIDENT_REMEDIATION_RESULT}"
    printf '%s' "$template"
}

escape_html() {
    local value="$1"
    value="${value//&/\&amp;}"
    value="${value//</\&lt;}"
    value="${value//>/\&gt;}"
    printf '%s' "$value"
}

escape_json() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\b'/\\b}"
    value="${value//$'\f'/\\f}"
    value="${value//$'\v'/\\u000b}"
    printf '%s' "$value"
}

render_webhook_template() {
    local format="$1" template="$2" event="$3" timestamp="$4"
    local service detail check_type http_status check_exit action_status consecutive_unavailable escalation_count node_id match_count threshold comparator since

    service="$CURRENT_SERVICE"
    detail="$(sanitize_detail "$CHECK_DETAIL")"
    check_type="$CURRENT_CHECK_TYPE"
    http_status="${CHECK_HTTP_STATUS:-n/a}"
    check_exit="${CHECK_EXIT_CODE:-n/a}"
    action_status="$CURRENT_ACTION_STATUS"
    consecutive_unavailable="$ESCALATION_CONSECUTIVE_UNAVAILABLE"
    escalation_count="$ESCALATION_COUNT"
    node_id="$(yaml_read '.federation.node_id // ""')"
    [[ -n "$node_id" ]] || node_id="$(hostname -s)"
    match_count="${MATCH_COUNT:-n/a}"
    threshold="${THRESHOLD_VALUE:-n/a}"
    comparator="${THRESHOLD_COMPARATOR:-n/a}"
    since="${THRESHOLD_SINCE:-n/a}"
    case "$format" in
        html)
            service="$(escape_html "$service")"; detail="$(escape_html "$detail")"
            check_type="$(escape_html "$check_type")"; http_status="$(escape_html "$http_status")"
            check_exit="$(escape_html "$check_exit")"; action_status="$(escape_html "$action_status")"
            node_id="$(escape_html "$node_id")"; match_count="$(escape_html "$match_count")"
            threshold="$(escape_html "$threshold")"; comparator="$(escape_html "$comparator")"; since="$(escape_html "$since")"
            ;;
        json)
            service="$(escape_json "$service")"; detail="$(escape_json "$detail")"
            check_type="$(escape_json "$check_type")"; http_status="$(escape_json "$http_status")"
            check_exit="$(escape_json "$check_exit")"; action_status="$(escape_json "$action_status")"
            node_id="$(escape_json "$node_id")"; match_count="$(escape_json "$match_count")"
            threshold="$(escape_json "$threshold")"; comparator="$(escape_json "$comparator")"; since="$(escape_json "$since")"
            ;;
    esac
    template="${template//\{\{service\}\}/$service}"
    template="${template//\{\{event\}\}/$event}"
    template="${template//\{\{timestamp\}\}/$timestamp}"
    template="${template//\{\{check_type\}\}/$check_type}"
    template="${template//\{\{detail\}\}/$detail}"
    template="${template//\{\{node_id\}\}/$node_id}"
    template="${template//\{\{match_count\}\}/$match_count}"
    template="${template//\{\{threshold\}\}/$threshold}"
    template="${template//\{\{comparator\}\}/$comparator}"
    template="${template//\{\{since\}\}/$since}"
    template="${template//\{\{http_status\}\}/$http_status}"
    template="${template//\{\{check_exit\}\}/$check_exit}"
    template="${template//\{\{action_status\}\}/$action_status}"
    template="${template//\{\{consecutive_unavailable\}\}/$consecutive_unavailable}"
    template="${template//\{\{escalation_count\}\}/$escalation_count}"
    template="${template//\{\{incident_id\}\}/$INCIDENT_ID}"
    template="${template//\{\{incident_duration_seconds\}\}/$INCIDENT_DURATION}"
    template="${template//\{\{remediation_result\}\}/$INCIDENT_REMEDIATION_RESULT}"
    printf '%s' "$template"
}

webhook_template() {
    local webhook="$1" event="$2" fallback value value_type
    case "${webhook}:${event}" in
        telegram:failure) fallback=$'🚨 <b>{{service}}</b> DOWN\n\nType: {{check_type}}\nDetail: {{detail}}\nTime: {{timestamp}}' ;;
        telegram:recovery) fallback=$'✅ <b>{{service}}</b> UP\n\nRecovered at {{timestamp}} after {{incident_duration_seconds}}s ({{remediation_result}})' ;;
        telegram:escalation) fallback=$'⚠️ <b>ESCALATION:</b> {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.' ;;
        telegram:circuit_open) fallback='⚠️ <b>CIRCUIT BREAKER OPEN:</b> {{service}}' ;;
        telegram:circuit_close) fallback='✅ <b>CIRCUIT BREAKER CLOSED:</b> {{service}}' ;;
        telegram:flapping) fallback='⚠️ <b>FLAPPING:</b> {{service}} is unstable; automatic remediation paused.' ;;
        discord:failure) fallback='{"content":"🚨 **{{service}}** is unavailable: {{detail}}"}' ;;
        discord:recovery) fallback='{"content":"✅ **{{service}}** recovered after {{incident_duration_seconds}}s ({{remediation_result}})"}' ;;
        discord:escalation) fallback='{"content":"⚠️ **ESCALATION:** {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks."}' ;;
        discord:circuit_open) fallback='{"content":"⚠️ **CIRCUIT BREAKER OPEN:** {{service}}"}' ;;
        discord:circuit_close) fallback='{"content":"✅ **CIRCUIT BREAKER CLOSED:** {{service}}"}' ;;
        discord:flapping) fallback='{"content":"⚠️ **FLAPPING:** {{service}} is unstable; automatic remediation paused."}' ;;
        slack:failure) fallback='{"text":"🚨 {{service}} DOWN: {{detail}}"}' ;;
        slack:recovery) fallback='{"text":"✅ {{service}} recovered after {{incident_duration_seconds}}s ({{remediation_result}})"}' ;;
        slack:escalation) fallback='{"text":"⚠️ ESCALATION: {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks."}' ;;
        slack:circuit_open) fallback='{"text":"⚠️ CIRCUIT BREAKER OPEN: {{service}}"}' ;;
        slack:circuit_close) fallback='{"text":"✅ CIRCUIT BREAKER CLOSED: {{service}}"}' ;;
        slack:flapping) fallback='{"text":"⚠️ FLAPPING: {{service}} is unstable; automatic remediation paused."}' ;;
        ntfy:failure) fallback='🚨 {{service}} unavailable: {{detail}}' ;;
        ntfy:recovery) fallback='✅ {{service}} recovered after {{incident_duration_seconds}}s ({{remediation_result}})' ;;
        ntfy:escalation) fallback='⚠️ ESCALATION: {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.' ;;
        ntfy:circuit_open) fallback='⚠️ CIRCUIT BREAKER OPEN: {{service}}' ;;
        ntfy:circuit_close) fallback='✅ CIRCUIT BREAKER CLOSED: {{service}}' ;;
        ntfy:flapping) fallback='⚠️ FLAPPING: {{service}} is unstable; automatic remediation paused.' ;;
        pagerduty:failure|opsgenie:failure) fallback='{{service}} unavailable: {{detail}}' ;;
        pagerduty:recovery|opsgenie:recovery) fallback='{{service}} recovered after {{incident_duration_seconds}}s ({{remediation_result}})' ;;
        pagerduty:escalation|opsgenie:escalation) fallback='ESCALATION: {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.' ;;
        *) return 1 ;;
    esac
    value_type="$(yaml_read ".notifications.webhooks.${webhook}.template.${event} | type")"
    if [[ "$value_type" == "!!null" ]]; then
        value="$fallback"
    else
        value="$(yaml_read ".notifications.webhooks.${webhook}.template.${event}")"
    fi
    printf '%s' "$value"
}

oncall_incident_key() {
    local incident_id="$INCIDENT_ID"
    [[ -n "$incident_id" ]] || incident_id="${CURRENT_SERVICE}-untracked"
    printf 'watchdog-%s' "$incident_id"
}

oncall_provider_handles_event() {
    case "$1" in failure|recovery|escalation) return 0 ;; *) return 1 ;; esac
}

send_single_webhook() {
    local webhook="$1" event="$2" env_name="" secret="" url="" template text timestamp
    local response_file response http_status curl_status thread_id priority error_file error_text payload_file='' secret_config=''
    local -a curl_command

    case "$webhook" in
        telegram) env_name="$(yaml_read '.notifications.webhooks.telegram.bot_token_env')" ;;
        discord|slack) env_name="$(yaml_read ".notifications.webhooks.${webhook}.webhook_url_env")" ;;
        ntfy) env_name="$(yaml_read '.notifications.webhooks.ntfy.token_env // ""')" ;;
        pagerduty) env_name="$(yaml_read '.notifications.webhooks.pagerduty.routing_key_env')" ;;
        opsgenie) env_name="$(yaml_read '.notifications.webhooks.opsgenie.api_key_env')" ;;
    esac
    if [[ -n "$env_name" ]]; then
        secret="${!env_name:-}"
        if [[ -z "$secret" ]]; then
            NOTIFY_TEST_DETAIL="missing environment variable ${env_name}"
            if (( NOTIFY_TEST_MODE == 1 )); then
                log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=test-webhook-failed reason=missing-env:${env_name} event=${event}"
            else
                log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=webhook-failed reason=missing-env:${env_name} event=${event}"
            fi
            return 1
        fi
    fi

    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    template="$(webhook_template "$webhook" "$event")" || return 1
    response_file="${TEMP_DIRECTORY}/webhook-${webhook}-${RANDOM}.response"
    curl_command=(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --connect-timeout 10 --max-time 30)
    case "$webhook" in
        telegram)
            text="$(render_webhook_template html "$template" "$event" "$timestamp")"
            (( NOTIFY_TEST_MODE == 0 )) || text="[TEST] ${text}"
            url="https://api.telegram.org/bot${secret}/sendMessage"
            thread_id="$(yaml_read '.notifications.webhooks.telegram.thread_id // ""')"
            curl_command+=(--request POST --data-urlencode "chat_id=$(yaml_read '.notifications.webhooks.telegram.chat_id')" --data-urlencode "text=${text}" --data-urlencode 'parse_mode=HTML')
            [[ -z "$thread_id" ]] || curl_command+=(--data-urlencode "message_thread_id=${thread_id}")
            ;;
        discord|slack)
            text="$(render_webhook_template json "$template" "$event" "$timestamp")"
            if (( NOTIFY_TEST_MODE == 1 )); then
                if [[ "$webhook" == discord ]]; then
                    text="$(printf '%s' "$text" | yq eval -p=json -o=json -I=0 '.content = "[TEST] " + (.content // "")' - 2>/dev/null)" || {
                        NOTIFY_TEST_DETAIL='invalid JSON webhook template'
                        log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=test-webhook-failed reason=invalid-template event=${event}"
                        return 1
                    }
                else
                    text="$(printf '%s' "$text" | yq eval -p=json -o=json -I=0 '.text = "[TEST] " + (.text // "")' - 2>/dev/null)" || {
                        NOTIFY_TEST_DETAIL='invalid JSON webhook template'
                        log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=test-webhook-failed reason=invalid-template event=${event}"
                        return 1
                    }
                fi
            fi
            url="$secret"
            curl_command+=(--request POST --header 'Content-Type: application/json' --data "$text")
            ;;
        ntfy)
            text="$(render_webhook_template plain "$template" "$event" "$timestamp")"
            (( NOTIFY_TEST_MODE == 0 )) || text="[TEST] ${text}"
            url="$(yaml_read '.notifications.webhooks.ntfy.url')"
            priority="$(yaml_read '.notifications.webhooks.ntfy.priority // "default"')"
            if (( NOTIFY_TEST_MODE == 1 )); then
                curl_command+=(--request POST --header 'Title: [TEST] watchdog' --header "Priority: ${priority}" --data-binary "$text")
            else
                curl_command+=(--request POST --header 'Title: watchdog' --header "Priority: ${priority}" --data-binary "$text")
            fi
            [[ -z "$secret" ]] || curl_command+=(--header "Authorization: Bearer ${secret}")
            ;;
        pagerduty)
            text="$(render_webhook_template plain "$template" "$event" "$timestamp")"
            (( NOTIFY_TEST_MODE == 0 )) || text="[TEST] ${text}"
            url='https://events.pagerduty.com/v2/enqueue'
            case "$event" in
                recovery)
                    text="$(printf '{"routing_key":"%s","event_action":"resolve","dedup_key":"%s"}' \
                        "$(escape_json "$secret")" "$(escape_json "$(oncall_incident_key)")")"
                    ;;
                escalation)
                    text="$(printf '{"routing_key":"%s","event_action":"trigger","dedup_key":"%s","payload":{"summary":"%s","source":"%s","severity":"critical"}}' \
                        "$(escape_json "$secret")" "$(escape_json "$(oncall_incident_key)")" "$(escape_json "$text")" "$(escape_json "$CURRENT_SERVICE")")"
                    ;;
                *)
                    text="$(printf '{"routing_key":"%s","event_action":"trigger","dedup_key":"%s","payload":{"summary":"%s","source":"%s","severity":"error"}}' \
                        "$(escape_json "$secret")" "$(escape_json "$(oncall_incident_key)")" "$(escape_json "$text")" "$(escape_json "$CURRENT_SERVICE")")"
                    ;;
            esac
            payload_file="$(mktemp "${TEMP_DIRECTORY}/pagerduty-payload.XXXXXX")" || {
                log ERROR "service=${CURRENT_SERVICE} webhook=pagerduty result=webhook-failed reason=payload-file-create event=${event}"
                return 1
            }
            chmod 0600 "$payload_file" 2>/dev/null || true
            if ! printf '%s' "$text" >"$payload_file"; then
                rm -f -- "$payload_file"
                log ERROR "service=${CURRENT_SERVICE} webhook=pagerduty result=webhook-failed reason=payload-file-write event=${event}"
                return 1
            fi
            curl_command+=(--request POST --header 'Content-Type: application/json' --data-binary "@${payload_file}")
            ;;
        opsgenie)
            text="$(render_webhook_template plain "$template" "$event" "$timestamp")"
            (( NOTIFY_TEST_MODE == 0 )) || text="[TEST] ${text}"
            if [[ "$(yaml_read '.notifications.webhooks.opsgenie.region // "us"')" == eu ]]; then
                url='https://api.eu.opsgenie.com/v2/alerts'
            else
                url='https://api.opsgenie.com/v2/alerts'
            fi
            case "$event" in
                recovery)
                    url+="/$(oncall_incident_key)/close?identifierType=alias"
                    text="$(printf '{"source":"watchdog","note":"%s"}' "$(escape_json "$text")")"
                    ;;
                escalation)
                    text="$(printf '{"message":"%s","alias":"%s","description":"%s","priority":"P1","source":"watchdog"}' \
                        "$(escape_json "${text:0:130}")" "$(escape_json "$(oncall_incident_key)")" "$(escape_json "$text")")"
                    ;;
                *)
                    text="$(printf '{"message":"%s","alias":"%s","description":"%s","priority":"P2","source":"watchdog"}' \
                        "$(escape_json "${text:0:130}")" "$(escape_json "$(oncall_incident_key)")" "$(escape_json "$text")")"
                    ;;
            esac
            payload_file="$(mktemp "${TEMP_DIRECTORY}/opsgenie-payload.XXXXXX")" || {
                log ERROR "service=${CURRENT_SERVICE} webhook=opsgenie result=webhook-failed reason=payload-file-create event=${event}"
                return 1
            }
            secret_config="$(mktemp "${TEMP_DIRECTORY}/opsgenie-auth.XXXXXX")" || {
                rm -f -- "$payload_file"
                log ERROR "service=${CURRENT_SERVICE} webhook=opsgenie result=webhook-failed reason=auth-file-create event=${event}"
                return 1
            }
            chmod 0600 "$payload_file" "$secret_config" 2>/dev/null || true
            if ! printf '%s' "$text" >"$payload_file" ||
                ! printf 'header = "%s"\n' "$(escape_curl_config_value "Authorization: GenieKey ${secret}")" >"$secret_config"; then
                rm -f -- "$payload_file" "$secret_config"
                log ERROR "service=${CURRENT_SERVICE} webhook=opsgenie result=webhook-failed reason=request-file-write event=${event}"
                return 1
            fi
            curl_command+=(--request POST --header 'Content-Type: application/json' --config "$secret_config" --data-binary "@${payload_file}")
            ;;
    esac

    if (( NOTIFY_TEST_MODE == 1 )); then
        error_file="${TEMP_DIRECTORY}/webhook-${webhook}-${RANDOM}.error"
        http_status="$("${curl_command[@]}" "$url" 2>"$error_file")"
    else
        http_status="$("${curl_command[@]}" "$url" 2>/dev/null)"
    fi
    curl_status=$?
    response=""; [[ -s "$response_file" ]] && response="$(<"$response_file")"
    error_text=""; [[ -z "${error_file:-}" || ! -s "$error_file" ]] || error_text="$(<"$error_file")"
    rm -f -- "$response_file"
    [[ -z "${error_file:-}" ]] || rm -f -- "$error_file"
    rm -f -- "$payload_file" "$secret_config"
    if (( curl_status == 0 )) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        if [[ "$webhook" != telegram || "$response" =~ \"ok\"[[:space:]]*:[[:space:]]*true ]]; then
            if (( NOTIFY_TEST_MODE == 1 )); then
                NOTIFY_TEST_DETAIL="HTTP ${http_status}"
                log INFO "service=${CURRENT_SERVICE} webhook=${webhook} result=test-webhook-sent event=${event} http_status=${http_status}"
            else
                log INFO "service=${CURRENT_SERVICE} webhook=${webhook} result=webhook-sent event=${event} http_status=${http_status}"
            fi
            return 0
        fi
    fi
    if (( NOTIFY_TEST_MODE == 1 )); then
        if (( curl_status != 0 )); then
            [[ -z "$secret" ]] || error_text="${error_text//"$secret"/[REDACTED]}"
            NOTIFY_TEST_DETAIL="curl exit ${curl_status}: $(sanitize_detail "${error_text:-request failed}")"
        else
            NOTIFY_TEST_DETAIL="HTTP ${http_status:-000}"
        fi
        log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=test-webhook-failed event=${event} curl_exit=${curl_status} http_status=${http_status:-000}"
    else
        log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=webhook-failed event=${event} curl_exit=${curl_status} http_status=${http_status:-000}"
    fi
    return 1
}

send_webhook_notification() {
    local event="$1" webhook enabled failed=0
    for webhook in telegram discord slack ntfy pagerduty opsgenie; do
        enabled="$(yaml_read ".notifications.webhooks.${webhook}.enabled // false")"
        [[ "$enabled" == true ]] || continue
        oncall_provider_handles_event "$event" || [[ "$webhook" != pagerduty && "$webhook" != opsgenie ]] || continue
        send_single_webhook "$webhook" "$event" || failed=1
    done
    return "$failed"
}

log_notification_plan() {
    local service_name="$1" event="$2" webhook
    (( EMAIL_ENABLED == 0 )) || log INFO "service=${service_name} action=email result=would-send event=${event}"
    for webhook in telegram discord slack ntfy pagerduty opsgenie; do
        if [[ "$(yaml_read ".notifications.webhooks.${webhook}.enabled // false")" == true ]]; then
            oncall_provider_handles_event "$event" || [[ "$webhook" != pagerduty && "$webhook" != opsgenie ]] || continue
            log INFO "service=${service_name} action=webhook result=would-send provider=${webhook} event=${event}"
        fi
    done
}

escape_curl_config_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

send_email_message() {
    local event="$1" subject="$2" body="$3"
    local encoded_subject message_file smtp_auth_file="" recipient recipients_header="" output command_status recipient_index
    local -a curl_command

    (( EMAIL_ENABLED == 1 )) || return 0
    subject="${subject//$'\r'/ }"
    subject="${subject//$'\n'/ }"
    encoded_subject="$(printf '%s' "$subject" | base64 | tr -d '\r\n')"
    message_file="${TEMP_DIRECTORY}/email-${RANDOM}-${RANDOM}.eml"
    curl_command=(
        curl
        --silent
        --show-error
        --url "$EMAIL_SMTP_URL"
        --connect-timeout "$EMAIL_TIMEOUT"
        --max-time "$EMAIL_TIMEOUT"
        --mail-from "$EMAIL_FROM"
    )
    (( EMAIL_TLS_REQUIRED == 1 )) && curl_command+=(--ssl-reqd)
    (( EMAIL_INSECURE_SKIP_VERIFY == 1 )) && curl_command+=(--insecure)
    if [[ -n "$EMAIL_USERNAME" ]]; then
        smtp_auth_file="$(mktemp "${TEMP_DIRECTORY}/smtp-auth.XXXXXX")" || {
            log ERROR "service=${CURRENT_SERVICE} result=email-failed event=${event} reason=auth-file-create"
            return 1
        }
        if ! chmod 0600 "$smtp_auth_file" ||
            ! printf 'user = "%s"\n' "$(escape_curl_config_value "${EMAIL_USERNAME}:${EMAIL_PASSWORD}")" >"$smtp_auth_file"; then
            rm -f -- "$smtp_auth_file"
            log ERROR "service=${CURRENT_SERVICE} result=email-failed event=${event} reason=auth-file-write"
            return 1
        fi
        curl_command+=(--config "$smtp_auth_file")
    fi
    for ((recipient_index = 0; recipient_index < EMAIL_RECIPIENTS_COUNT; recipient_index++)); do
        recipient="$(yaml_read ".notifications.email.recipients[$recipient_index]")"
        curl_command+=(--mail-rcpt "$recipient")
        [[ -z "$recipients_header" ]] || recipients_header+=", "
        recipients_header+="$recipient"
    done
    {
        printf 'From: %s\r\n' "$EMAIL_FROM"
        printf 'To: %s\r\n' "$recipients_header"
        printf 'Subject: =?UTF-8?B?%s?=\r\n' "$encoded_subject"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n%s\r\n' "$body"
    } >"$message_file"
    log INFO "service=${CURRENT_SERVICE} action=email event=${event} recipients=${EMAIL_RECIPIENTS_COUNT}"
    output="$("${curl_command[@]}" --upload-file "$message_file" 2>&1)"
    command_status=$?
    rm -f -- "$message_file"
    [[ -z "$smtp_auth_file" ]] || rm -f -- "$smtp_auth_file"
    output="$(sanitize_detail "$output")"
    [[ -z "$EMAIL_PASSWORD" ]] || output="${output//"$EMAIL_PASSWORD"/[REDACTED]}"
    if (( command_status == 0 )); then
        if (( NOTIFY_TEST_MODE == 1 )); then
            NOTIFY_TEST_DETAIL='sent'
            log INFO "service=${CURRENT_SERVICE} result=test-email-sent event=${event} recipients=${EMAIL_RECIPIENTS_COUNT}"
        else
            log INFO "service=${CURRENT_SERVICE} result=email-sent event=${event} recipients=${EMAIL_RECIPIENTS_COUNT}"
        fi
        return 0
    fi
    if (( NOTIFY_TEST_MODE == 1 )); then
        output="${output//"$EMAIL_SMTP_URL"/[SMTP_URL]}"
        NOTIFY_TEST_DETAIL="curl exit ${command_status}: ${output:-request failed}"
        log ERROR "service=${CURRENT_SERVICE} result=test-email-failed event=${event} curl_exit=${command_status}"
    else
        log ERROR "service=${CURRENT_SERVICE} result=email-failed event=${event} curl_exit=${command_status} error=${output:-unknown}"
    fi
    return 1
}

send_email_notification() {
    local event="$1"
    local timestamp subject_template body_template subject body

    (( EMAIL_ENABLED == 1 )) || return 0
    case "$event" in
        failure)
            subject_template="$EMAIL_FAILURE_SUBJECT"
            body_template="$EMAIL_FAILURE_BODY"
            ;;
        recovery)
            subject_template="$EMAIL_RECOVERY_SUBJECT"
            body_template="$EMAIL_RECOVERY_BODY"
            ;;
        escalation)
            subject_template="[ESCALATION] ${EMAIL_FAILURE_SUBJECT}"
            body_template=$'⚠️ ESCALATION — service {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.\n\n{{detail}}\n\n'
            body_template+="$EMAIL_FAILURE_BODY"
            ;;
        circuit_open)
            subject_template="[CIRCUIT BREAKER OPEN] ${CURRENT_SERVICE}"
            body_template='Circuit breaker opened after repeated failed remediation. Service: {{service}}. Detail: {{detail}}'
            ;;
        circuit_close)
            subject_template="[CIRCUIT BREAKER CLOSED] ${CURRENT_SERVICE}"
            body_template='Circuit breaker closed because the service is healthy again. Service: {{service}}.'
            ;;
        flapping)
            subject_template='[FLAPPING] {{service}} is unstable'
            body_template='Repeated state transitions were detected. Automatic remediation is paused for service {{service}}.'
            ;;
        *)
            log ERROR "service=${CURRENT_SERVICE} result=email-failed reason=unknown-event event=${event}"
            return 1
            ;;
    esac

    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    subject="$(render_email_template "$subject_template" "$event" "$timestamp")"
    body="$(render_email_template "$body_template" "$event" "$timestamp")"
    if [[ "$event" == recovery ]]; then
        body+=$'\n\n'
        body+="Incident: ${INCIDENT_ID:-n/a}; duration: ${INCIDENT_DURATION}s; remediation: ${INCIDENT_REMEDIATION_RESULT}."
    fi
    if (( NOTIFY_TEST_MODE == 1 )); then
        subject="[TEST] ${subject}"
        body="[TEST] ${body}"
    fi
    send_email_message "$event" "$subject" "$body"
}
