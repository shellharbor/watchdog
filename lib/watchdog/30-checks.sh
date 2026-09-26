http_status_is_successful() {
    local index="$1"
    local status="$2"
    local count item_index expected
    count="$(yaml_read "${CHECK_CONFIG_PATH}.success_status // [] | length")"
    if (( count == 0 )); then
        [[ "$status" =~ ^2[0-9][0-9]$ ]]
        return
    fi
    for ((item_index = 0; item_index < count; item_index++)); do
        expected="$(yaml_read "${CHECK_CONFIG_PATH}.success_status[$item_index]")"
        [[ "$status" == "$expected" ]] && return 0
    done
    return 1
}

check_http() {
    local index="$1"
    local url method follow_redirects timeout_value error_file body_file="" http_status content_type time_total curl_status error_output
    local header_count header_index header_name header_value header_value_env expected_content_type body_regex max_total_ms curl_output
    local -a curl_command
    url="$(yaml_read "${CHECK_CONFIG_PATH}.url")"
    method="$(yaml_read "${CHECK_CONFIG_PATH}.method // \"GET\"")"
    follow_redirects="$(yaml_read_true_default "${CHECK_CONFIG_PATH}.follow_redirects")"
    timeout_value="$(yaml_read "${CHECK_CONFIG_PATH}.timeout // ${DEFAULT_TIMEOUT}")"
    error_file="${TEMP_DIRECTORY}/http-${index}-${RANDOM}.err"

    body_regex="$(yaml_read "${CHECK_CONFIG_PATH}.expect.body_regex // \"\"")"
    if [[ -n "$body_regex" ]]; then
        body_file="$(mktemp "${TEMP_DIRECTORY}/http-${index}-body.XXXXXX")" || {
            CHECK_EXIT_CODE=2; CHECK_DETAIL='cannot create HTTP response temporary file'; return 1;
        }
        chmod 0600 "$body_file" 2>/dev/null || true
        curl_command=(curl --silent --show-error --output "$body_file" --max-filesize 65536 --write-out '%{http_code}\t%{content_type}\t%{time_total}'
            --connect-timeout "$timeout_value" --max-time "$timeout_value" --request "$method")
    else
        curl_command=(curl --silent --show-error --output /dev/null --write-out '%{http_code}\t%{content_type}\t%{time_total}'
        --connect-timeout "$timeout_value" --max-time "$timeout_value" --request "$method")
    fi
    header_count="$(yaml_read "${CHECK_CONFIG_PATH}.headers // [] | length")"
    for ((header_index = 0; header_index < header_count; header_index++)); do
        header_name="$(yaml_read "${CHECK_CONFIG_PATH}.headers[$header_index].name")"
        header_value_env="$(yaml_read "${CHECK_CONFIG_PATH}.headers[$header_index].value_env // \"\"")"
        if [[ -n "$header_value_env" ]]; then
            header_value="${!header_value_env:-}"
            if [[ -z "$header_value" ]]; then
                [[ -z "$body_file" ]] || rm -f -- "$body_file"
                CHECK_EXIT_CODE=2
                CHECK_DETAIL="missing HTTP header environment variable ${header_value_env}"
                return 1
            fi
            if [[ "$header_value" == *$'\r'* || "$header_value" == *$'\n'* ]]; then
                [[ -z "$body_file" ]] || rm -f -- "$body_file"
                CHECK_EXIT_CODE=2
                CHECK_DETAIL="HTTP header environment variable ${header_value_env} contains a newline"
                return 1
            fi
        else
            header_value="$(yaml_read "${CHECK_CONFIG_PATH}.headers[$header_index].value")"
        fi
        curl_command+=(--header "${header_name}: ${header_value}")
    done
    [[ "$follow_redirects" == "true" ]] && curl_command+=(--location --max-redirs 5)
    curl_command+=("$url")

    if [[ -n "$body_file" ]]; then
        curl_output="$( ( ulimit -f 128; "${curl_command[@]}" ) 2>"$error_file")"
    else
        curl_output="$("${curl_command[@]}" 2>"$error_file")"
    fi
    curl_status=$?
    error_output=""
    [[ -s "$error_file" ]] && error_output="$(sanitize_detail "$(<"$error_file")")"
    rm -f -- "$error_file"

    IFS=$'\t' read -r http_status content_type time_total <<<"$curl_output"
    CHECK_HTTP_STATUS="$http_status"
    CHECK_EXIT_CODE="$curl_status"
    CHECK_HTTP_TOTAL_MS=""
    CHECK_HTTP_MAX_TOTAL_MS="$(yaml_read "${CHECK_CONFIG_PATH}.expect.max_total_ms // \"\"")"
    if [[ "$time_total" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        CHECK_HTTP_TOTAL_MS="$(LC_ALL=C awk -v seconds="$time_total" 'BEGIN { printf "%.0f", seconds * 1000 }')"
    fi
    if (( curl_status != 0 )); then
        [[ -z "$body_file" ]] || rm -f -- "$body_file"
        CHECK_DETAIL="curl_exit=${curl_status}; HTTP ${http_status:-000}; ${error_output:-unknown error}"
        return 1
    fi
    if ! http_status_is_successful "$index" "$http_status"; then
        [[ -z "$body_file" ]] || rm -f -- "$body_file"
        CHECK_DETAIL="unexpected HTTP ${http_status:-unknown}"
        return 1
    fi
    expected_content_type="$(yaml_read "${CHECK_CONFIG_PATH}.expect.content_type // \"\"")"
    if [[ -n "$expected_content_type" ]]; then
        content_type="${content_type%%;*}"; content_type="${content_type,,}"
        expected_content_type="${expected_content_type%%;*}"; expected_content_type="${expected_content_type,,}"
        if [[ "$content_type" != "$expected_content_type" ]]; then
            [[ -z "$body_file" ]] || rm -f -- "$body_file"
            CHECK_DETAIL="HTTP ${http_status}; unexpected content type ${content_type:-none}"
            return 1
        fi
    fi
    if [[ -n "$body_file" ]]; then
        if ! grep -Eq -- "$body_regex" "$body_file"; then
            rm -f -- "$body_file"
            CHECK_DETAIL="HTTP ${http_status}; response body did not match expect.body_regex"
            return 1
        fi
        rm -f -- "$body_file"
    fi
    max_total_ms="$CHECK_HTTP_MAX_TOTAL_MS"
    if [[ "$max_total_ms" =~ ^[0-9]+$ && "$CHECK_HTTP_TOTAL_MS" =~ ^[0-9]+$ ]] && (( 10#$CHECK_HTTP_TOTAL_MS > 10#$max_total_ms )); then
        CHECK_RESULT_STATE=degraded
        CHECK_DETAIL="HTTP ${http_status}; total=${CHECK_HTTP_TOTAL_MS}ms exceeds max_total_ms=${max_total_ms}ms"
        return 1
    fi
    CHECK_DETAIL="HTTP ${http_status}${CHECK_HTTP_TOTAL_MS:+; total=${CHECK_HTTP_TOTAL_MS}ms}"
    return 0
}

check_tcp() {
    local index="$1"
    local host port timeout_value command_status
    host="$(yaml_read "${CHECK_CONFIG_PATH}.host")"
    port="$(yaml_read "${CHECK_CONFIG_PATH}.port")"
    timeout_value="$(yaml_read "${CHECK_CONFIG_PATH}.timeout // ${DEFAULT_TIMEOUT}")"
    # $1 and $2 are intentionally expanded by the inner Bash process.
    # shellcheck disable=SC2016
    timeout --signal=TERM --kill-after=2s "$timeout_value" \
        bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1
    command_status=$?
    CHECK_EXIT_CODE="$command_status"
    if (( command_status == 0 )); then
        CHECK_DETAIL="TCP ${host}:${port} accepts connections"
        return 0
    fi
    CHECK_DETAIL="TCP ${host}:${port} unavailable; exit=${command_status}"
    return 1
}

run_configured_sequence() {
    local expression="$1"
    local label="$2"
    local service_name="$3"
    local count command_index working_directory timeout_value output_file output command_status formatted
    local -a configured_command

    count="$(yaml_read "${expression} // [] | length")"
    (( count > 0 )) || return 0

    for ((command_index = 0; command_index < count; command_index++)); do
        load_command "${expression}[$command_index].command" configured_command
        if [[ "$label" == remediation || ( "$label" == escalation && "$expression" == *.actions.commands ) ]] &&
            ! security_policy_check_command configured_command; then
            log ERROR "service=${service_name} action=${label}-command index=${command_index} result=blocked reason=security_policy"
            return 1
        fi
        working_directory="$(yaml_read "${expression}[$command_index].working_directory // \"/\"")"
        timeout_value="$(yaml_read "${expression}[$command_index].timeout // ${DEFAULT_ACTION_TIMEOUT}")"
        formatted="$(format_command configured_command)"
        output_file="${TEMP_DIRECTORY}/${label}-${RANDOM}.log"
        if (( PARALLEL_CHECK_MODE == 1 )) && [[ "$label" == check ]]; then
            printf 'service=%s action=%s-command index=%s command=%s\n' "$service_name" "$label" "$command_index" "$formatted"
        else
            log WARN "service=${service_name} action=${label}-command index=${command_index} command=${formatted}"
        fi

        (
            cd -- "$working_directory" || exit 125
            export WATCHDOG_SERVICE="$service_name"
            export WATCHDOG_CHECK_TYPE="$CURRENT_CHECK_TYPE"
            export WATCHDOG_DETAIL="$CHECK_DETAIL"
            export WATCHDOG_HTTP_STATUS="$CHECK_HTTP_STATUS"
            export WATCHDOG_CHECK_EXIT="$CHECK_EXIT_CODE"
            export WATCHDOG_MATCH_COUNT="$MATCH_COUNT"
            export WATCHDOG_THRESHOLD="$THRESHOLD_VALUE"
            export WATCHDOG_COMPARATOR="$THRESHOLD_COMPARATOR"
            export WATCHDOG_SINCE="$THRESHOLD_SINCE"
            export WATCHDOG_EVENT="$label"
            export WATCHDOG_INCIDENT_ID="$INCIDENT_ID"
            export WATCHDOG_INCIDENT_DURATION="$INCIDENT_DURATION"
            export WATCHDOG_INCIDENT_REMEDIATION_RESULT="$INCIDENT_REMEDIATION_RESULT"
            export WATCHDOG_REMEDIATION_RESULT="$INCIDENT_REMEDIATION_RESULT"
            WATCHDOG_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S%z')"
            export WATCHDOG_TIMESTAMP
            timeout --signal=TERM --kill-after=10s "$timeout_value" "${configured_command[@]}"
        ) >"$output_file" 2>&1
        command_status=$?
        output=""
        [[ -s "$output_file" ]] && output="$(sanitize_detail "$(<"$output_file")")"
        rm -f -- "$output_file"

        if (( command_status != 0 )); then
            if (( PARALLEL_CHECK_MODE == 1 )) && [[ "$label" == check ]]; then
                printf 'service=%s result=%s-command-failed index=%s exit=%s output=%s\n' "$service_name" "$label" "$command_index" "$command_status" "${output:-none}"
            else
                log ERROR "service=${service_name} result=${label}-command-failed index=${command_index} exit=${command_status} output=${output:-none}"
            fi
            return 1
        fi
        if (( PARALLEL_CHECK_MODE == 1 )) && [[ "$label" == check ]]; then
            printf 'service=%s result=%s-command-success index=%s output=%s\n' "$service_name" "$label" "$command_index" "${output:-none}"
        else
            log WARN "service=${service_name} result=${label}-command-success index=${command_index} output=${output:-none}"
        fi
    done
    return 0
}

check_command() {
    local index="$1"
    if run_configured_sequence "${CHECK_CONFIG_PATH}.commands" check "$CURRENT_SERVICE"; then
        CHECK_EXIT_CODE=0
        CHECK_DETAIL="check command sequence succeeded"
        return 0
    fi
    CHECK_EXIT_CODE=1
    CHECK_DETAIL="check command sequence failed"
    return 1
}

check_disk() {
    local path timeout_value value_type minimum thresholds='' failed=0
    path="$(yaml_read "${CHECK_CONFIG_PATH}.path")"
    timeout_value="$(yaml_read "${CHECK_CONFIG_PATH}.timeout // ${DEFAULT_TIMEOUT}")"
    CHECK_HTTP_STATUS=''
    CHECK_EXIT_CODE=1
    if ! read_filesystem_usage "$path" "$timeout_value"; then
        CHECK_DETAIL="disk path=${path} reason=filesystem-unavailable"
        return 1
    fi
    value_type="$(yaml_read "${CHECK_CONFIG_PATH}.min_free_gb | type")"
    if [[ "$value_type" != '!!null' ]]; then
        minimum="$(yaml_read "${CHECK_CONFIG_PATH}.min_free_gb")"
        thresholds=" min_free_gb=${minimum}"
        if ! LC_ALL=C awk -v free="$FILESYSTEM_FREE_BYTES" -v threshold="$minimum" \
            'BEGIN { exit !(free >= threshold * 1073741824) }'; then
            failed=1
        fi
    fi
    value_type="$(yaml_read "${CHECK_CONFIG_PATH}.min_free_percent | type")"
    if [[ "$value_type" != '!!null' ]]; then
        minimum="$(yaml_read "${CHECK_CONFIG_PATH}.min_free_percent")"
        thresholds+=" min_free_percent=${minimum}"
        if ! LC_ALL=C awk -v free="$FILESYSTEM_FREE_BYTES" -v total="$FILESYSTEM_TOTAL_BYTES" \
            -v threshold="$minimum" 'BEGIN { exit !(free * 100 / total >= threshold) }'; then
            failed=1
        fi
    fi
    CHECK_DETAIL="disk path=${path} free_gb=${FILESYSTEM_FREE_GB} free_percent=${FILESYSTEM_FREE_PERCENT}${thresholds}"
    if (( failed == 1 )); then
        CHECK_DETAIL="low disk space; ${CHECK_DETAIL}"
        return 1
    fi
    CHECK_EXIT_CODE=0
    return 0
}

check_tls_cert() {
    local host port server_name timeout_value min_days_remaining expiration_output expires_at expires_epoch now_epoch remaining_seconds days_remaining
    host="$(yaml_read "${CHECK_CONFIG_PATH}.host")"
    port="$(yaml_read "${CHECK_CONFIG_PATH}.port // 443")"
    server_name="$(yaml_read "${CHECK_CONFIG_PATH}.server_name // \"\"")"
    [[ -n "$server_name" ]] || server_name="$host"
    timeout_value="$(yaml_read "${CHECK_CONFIG_PATH}.timeout // ${DEFAULT_TIMEOUT}")"
    min_days_remaining="$(yaml_read "${CHECK_CONFIG_PATH}.min_days_remaining")"
    CHECK_HTTP_STATUS=''
    CHECK_EXIT_CODE=1

    if ! expiration_output="$(
        timeout --signal=TERM --kill-after=2s "$timeout_value" \
            openssl s_client -connect "${host}:${port}" -servername "$server_name" </dev/null 2>/dev/null |
            openssl x509 -noout -enddate 2>/dev/null
    )"; then
        CHECK_DETAIL="tls_cert host=${host} port=${port} server_name=${server_name} reason=certificate-unavailable"
        return 1
    fi
    [[ "$expiration_output" == notAfter=* ]] || {
        CHECK_DETAIL="tls_cert host=${host} port=${port} server_name=${server_name} reason=invalid-expiry"
        return 1
    }
    expires_at="${expiration_output#notAfter=}"
    expires_epoch="$(LC_ALL=C date -u -d "$expires_at" '+%s' 2>/dev/null)"
    if ! is_non_negative_integer "$expires_epoch"; then
        CHECK_DETAIL="tls_cert host=${host} port=${port} server_name=${server_name} reason=invalid-expiry"
        return 1
    fi
    now_epoch="$(date '+%s')"
    remaining_seconds=$((10#$expires_epoch - 10#$now_epoch))
    if (( remaining_seconds <= 0 )); then
        CHECK_DETAIL="tls_cert host=${host} port=${port} server_name=${server_name} expires_at=${expires_at} days_remaining=0 min_days_remaining=${min_days_remaining} reason=expired"
        return 1
    fi
    days_remaining=$((remaining_seconds / 86400))
    CHECK_DETAIL="tls_cert host=${host} port=${port} server_name=${server_name} expires_at=${expires_at} days_remaining=${days_remaining} min_days_remaining=${min_days_remaining}"
    if (( days_remaining < 10#$min_days_remaining )); then
        CHECK_DETAIL="certificate expiring soon; ${CHECK_DETAIL}"
        return 1
    fi
    CHECK_EXIT_CODE=0
    return 0
}

security_check_log() {
    local level="$1" message="$2"
    if (( PARALLEL_CHECK_MODE == 1 )); then
        printf '%s\n' "$message"
    else
        log "$level" "$message"
    fi
}

run_check_clamav() {
    local path recursive timeout_value output_file status detail threats
    local -a command_line=(clamscan)
    path="$(yaml_read "${CHECK_CONFIG_PATH}.path")"
    recursive="$(yaml_read "${CHECK_CONFIG_PATH}.recursive // false")"
    timeout_value="$(yaml_read "${CHECK_CONFIG_PATH}.timeout // 300")"
    [[ "$recursive" != true ]] || command_line+=(-r)
    command_line+=("$path")
    output_file="${TEMP_DIRECTORY}/clamav-${RANDOM}.out"
    timeout --signal=TERM --kill-after=2s "$timeout_value" "${command_line[@]}" >"$output_file" 2>&1
    status=$?
    CHECK_EXIT_CODE="$status"; CHECK_HTTP_STATUS=''
    detail="$(tail -c 2000 -- "$output_file" | tr '\r\n' '  ')"
    threats="$(grep -c 'FOUND$' "$output_file")" || true
    rm -f -- "$output_file"
    case "$status" in
        0)
            CHECK_DETAIL=''
            security_check_log INFO "service=${CURRENT_SERVICE} check=clamav path=${path} recursive=${recursive} result=clean exit=0"
            return 0 ;;
        1)
            CHECK_DETAIL="${detail:-virus found}"
            security_check_log WARN "service=${CURRENT_SERVICE} check=clamav result=virus_found threats=${threats:-0} detail=\"$(sanitize_detail "$CHECK_DETAIL")\" exit=1"
            return 1 ;;
        *)
            if [[ "$detail" == *'Permission denied'* || "$detail" == *"Can't open"* ]]; then
                CHECK_DETAIL="cannot read path: ${path}"
            else
                CHECK_DETAIL="clamscan error: ${detail:-exit ${status}}"
            fi
            CHECK_DETAIL="$(printf '%s' "$CHECK_DETAIL" | tail -c 2000)"
            security_check_log ERROR "service=${CURRENT_SERVICE} check=clamav result=error detail=\"$(sanitize_detail "$CHECK_DETAIL")\" exit=${status}"
            return 1 ;;
    esac
}

threshold_count_pattern() {
    local pattern="$1" input_file="$2" status
    MATCH_COUNT="$(grep -E -c -- "$pattern" "$input_file" 2>/dev/null)"
    status=$?
    (( status <= 1 )) || { CHECK_DETAIL='threshold pattern evaluation failed'; CHECK_EXIT_CODE="$status"; return 1; }
    [[ "$MATCH_COUNT" =~ ^[0-9]+$ ]] || { CHECK_DETAIL='threshold count is not numeric'; CHECK_EXIT_CODE=2; return 1; }
}

threshold_source_error() {
    local source_type="$1" status="$2" error_file="$3" reason
    reason="$(tail -c 500 -- "$error_file" | tr '\r\n' '  ')"
    CHECK_EXIT_CODE="$status"
    CHECK_DETAIL="${source_type} source error: ${reason:-exit ${status}}"
    return 1
}

_count_journald() {
    local timeout_value="$1" output_file="$2" error_file="$3" unit since pattern status
    unit="$(yaml_read "${CHECK_CONFIG_PATH}.source.unit")"
    since="$(yaml_read "${CHECK_CONFIG_PATH}.source.since")"
    pattern="$(yaml_read "${CHECK_CONFIG_PATH}.source.pattern")"
    THRESHOLD_SINCE="$since"
    timeout --signal=TERM --kill-after=2s "$timeout_value" journalctl --unit "$unit" --since "$since" --no-pager --output=cat >"$output_file" 2>"$error_file"
    status=$?
    (( status == 0 )) || { threshold_source_error journald "$status" "$error_file"; return 1; }
    threshold_count_pattern "$pattern" "$output_file"
}

_count_logfile() {
    local timeout_value="$1" output_file="$2" error_file="$3" path lines pattern status
    path="$(yaml_read "${CHECK_CONFIG_PATH}.source.path")"
    lines="$(yaml_read "${CHECK_CONFIG_PATH}.source.tail_lines // 10000")"
    pattern="$(yaml_read "${CHECK_CONFIG_PATH}.source.pattern")"
    timeout --signal=TERM --kill-after=2s "$timeout_value" tail -n "$lines" -- "$path" >"$output_file" 2>"$error_file"
    status=$?
    (( status == 0 )) || { threshold_source_error logfile "$status" "$error_file"; return 1; }
    threshold_count_pattern "$pattern" "$output_file"
}

_count_netstat() {
    local timeout_value="$1" output_file="$2" error_file="$3" state pattern status normalized
    state="$(yaml_read "${CHECK_CONFIG_PATH}.source.state // \"\"")"
    pattern="$(yaml_read "${CHECK_CONFIG_PATH}.source.pattern // \"\"")"
    if command -v ss >/dev/null 2>&1; then
        if [[ -n "$state" ]]; then
            timeout --signal=TERM --kill-after=2s "$timeout_value" ss -H -tan state "${state,,}" >"$output_file" 2>"$error_file"
        else
            timeout --signal=TERM --kill-after=2s "$timeout_value" ss -H -tan >"$output_file" 2>"$error_file"
        fi
        status=$?
        (( status == 0 )) || { threshold_source_error netstat "$status" "$error_file"; return 1; }
        if [[ -n "$state" ]]; then MATCH_COUNT="$(wc -l <"$output_file")"; else threshold_count_pattern "$pattern" "$output_file" || return 1; fi
    else
        timeout --signal=TERM --kill-after=2s "$timeout_value" netstat -tan >"$output_file" 2>"$error_file"
        status=$?
        (( status == 0 )) || { threshold_source_error netstat "$status" "$error_file"; return 1; }
        if [[ -n "$state" ]]; then
            normalized="${state^^}"; normalized="${normalized//-/_}"
            MATCH_COUNT="$(awk -v target="$normalized" '$1 ~ /^tcp/ && toupper($NF) == target { count++ } END { print count+0 }' "$output_file")"
        else
            threshold_count_pattern "$pattern" "$output_file" || return 1
        fi
    fi
    MATCH_COUNT="${MATCH_COUNT//[[:space:]]/}"
    [[ "$MATCH_COUNT" =~ ^[0-9]+$ ]] || { CHECK_DETAIL='netstat count is not numeric'; CHECK_EXIT_CODE=2; return 1; }
}

_count_command() {
    local timeout_value="$1" output_file="$2" error_file="$3" pattern status source_timeout count=''
    local -a source_command=()
    load_command "${CHECK_CONFIG_PATH}.source.command" source_command
    source_timeout="$(yaml_read "${CHECK_CONFIG_PATH}.source.timeout // ${timeout_value}")"
    timeout --signal=TERM --kill-after=2s "$source_timeout" "${source_command[@]}" >"$output_file" 2>"$error_file"
    status=$?
    (( status == 0 )) || { threshold_source_error command "$status" "$error_file"; return 1; }
    pattern="$(yaml_read "${CHECK_CONFIG_PATH}.source.pattern // \"\"")"
    if [[ -n "$pattern" ]]; then
        threshold_count_pattern "$pattern" "$output_file"
    else
        IFS= read -r count <"$output_file" || true
        count="${count//[[:space:]]/}"
        [[ "$count" =~ ^[0-9]+$ ]] || { CHECK_DETAIL='command source must output a non-negative integer'; CHECK_EXIT_CODE=2; return 1; }
        MATCH_COUNT="$count"
    fi
}

_compare_numbers() {
    local count="$1" threshold="$2" comparator="$3"
    LC_ALL=C awk -v count="$count" -v threshold="$threshold" -v operator="$comparator" 'BEGIN {
        if (operator == ">") exit !(count > threshold)
        if (operator == ">=") exit !(count >= threshold)
        if (operator == "<") exit !(count < threshold)
        if (operator == "<=") exit !(count <= threshold)
        if (operator == "==") exit !(count == threshold)
        if (operator == "!=") exit !(count != threshold)
        exit 2
    }'
}

run_check_threshold() {
    local source_type timeout_value output_file error_file status comparison_status
    source_type="$(yaml_read "${CHECK_CONFIG_PATH}.source.type")"
    timeout_value="$(yaml_read "${CHECK_CONFIG_PATH}.timeout // ${DEFAULT_TIMEOUT}")"
    THRESHOLD_VALUE="$(yaml_read "${CHECK_CONFIG_PATH}.threshold")"
    THRESHOLD_COMPARATOR="$(yaml_read "${CHECK_CONFIG_PATH}.comparator // \">\"")"
    MATCH_COUNT=''; THRESHOLD_SINCE=''; CHECK_HTTP_STATUS=''; CHECK_EXIT_CODE=0
    output_file="${TEMP_DIRECTORY}/threshold-${RANDOM}.out"
    error_file="${TEMP_DIRECTORY}/threshold-${RANDOM}.err"
    case "$source_type" in
        journald) _count_journald "$timeout_value" "$output_file" "$error_file" ; status=$? ;;
        logfile) _count_logfile "$timeout_value" "$output_file" "$error_file" ; status=$? ;;
        netstat) _count_netstat "$timeout_value" "$output_file" "$error_file" ; status=$? ;;
        command) _count_command "$timeout_value" "$output_file" "$error_file" ; status=$? ;;
        *) CHECK_DETAIL='unsupported threshold source'; CHECK_EXIT_CODE=2; status=1 ;;
    esac
    rm -f -- "$output_file" "$error_file"
    if (( status != 0 )); then
        security_check_log ERROR "service=${CURRENT_SERVICE} check=threshold source=${source_type} result=error detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
        return 1
    fi
    _compare_numbers "$MATCH_COUNT" "$THRESHOLD_VALUE" "$THRESHOLD_COMPARATOR"
    comparison_status=$?
    if (( comparison_status == 0 )); then
        CHECK_DETAIL="${MATCH_COUNT} matches (threshold: ${THRESHOLD_VALUE} ${THRESHOLD_COMPARATOR})"
        security_check_log WARN "service=${CURRENT_SERVICE} check=threshold source=${source_type} count=${MATCH_COUNT} threshold=${THRESHOLD_VALUE} comparator=${THRESHOLD_COMPARATOR} result=threshold_exceeded"
        return 1
    fi
    if (( comparison_status != 1 )); then
        CHECK_DETAIL='threshold comparison failed'; CHECK_EXIT_CODE=2
        security_check_log ERROR "service=${CURRENT_SERVICE} check=threshold source=${source_type} result=error reason=invalid-comparator"
        return 1
    fi
    CHECK_DETAIL=''
    security_check_log INFO "service=${CURRENT_SERVICE} check=threshold source=${source_type} count=${MATCH_COUNT} threshold=${THRESHOLD_VALUE} comparator=${THRESHOLD_COMPARATOR} result=below_threshold"
    return 0
}

perform_single_check() {
    local index="$1"
    case "$CURRENT_CHECK_TYPE" in
        http) check_http "$index" ;;
        tcp) check_tcp "$index" ;;
        command) check_command "$index" ;;
        disk) check_disk ;;
        tls_cert) check_tls_cert ;;
        clamav) run_check_clamav ;;
        threshold) run_check_threshold ;;
        *) return 1 ;;
    esac
}

check_with_retries() {
    local index="$1"
    local attempts retry_delay attempt started_epoch
    started_epoch="$(date '+%s')"
    HISTORY_CHECKED["$CURRENT_SERVICE"]=1
    attempts="$(yaml_read "${CHECK_CONFIG_PATH}.attempts // ${DEFAULT_ATTEMPTS}")"
    retry_delay="$(yaml_read "${CHECK_CONFIG_PATH}.retry_delay // ${DEFAULT_RETRY_DELAY}")"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        record_check_attempt "$CURRENT_SERVICE"
        log INFO "service=${CURRENT_SERVICE} action=check attempt=${attempt}/${attempts} type=${CURRENT_CHECK_TYPE}"
        CHECK_RESULT_STATE=unavailable
        if perform_single_check "$index"; then
            CHECK_RESULT_STATE=healthy
            record_http_timing "$CURRENT_SERVICE"
            HISTORY_CHECK_DURATION["$CURRENT_SERVICE"]=$(( ${HISTORY_CHECK_DURATION[$CURRENT_SERVICE]:-0} + $(date '+%s') - started_epoch ))
            (( DRY_RUN == 1 )) || write_service_marker_number "$CURRENT_SERVICE" last-success "$(date '+%s')"
            log INFO "service=${CURRENT_SERVICE} result=check-success attempt=${attempt}/${attempts} detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
            return 0
        fi
        record_http_timing "$CURRENT_SERVICE"
        if [[ "$CHECK_RESULT_STATE" == degraded ]]; then
            log WARN "service=${CURRENT_SERVICE} result=check-degraded attempt=${attempt}/${attempts} detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
        else
            increment_service_marker_number "$CURRENT_SERVICE" check-errors-total
            log WARN "service=${CURRENT_SERVICE} result=check-failed attempt=${attempt}/${attempts} detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
        fi
        if (( attempt < attempts && retry_delay > 0 )); then
            sleep "$retry_delay"
        fi
    done
    HISTORY_CHECK_DURATION["$CURRENT_SERVICE"]=$(( ${HISTORY_CHECK_DURATION[$CURRENT_SERVICE]:-0} + $(date '+%s') - started_epoch ))
    return 1
}

check_with_retries_parallel() {
    local index="$1" attempts retry_delay attempt
    attempts="$(yaml_read "${CHECK_CONFIG_PATH}.attempts // ${DEFAULT_ATTEMPTS}")"
    retry_delay="$(yaml_read "${CHECK_CONFIG_PATH}.retry_delay // ${DEFAULT_RETRY_DELAY}")"
    PARALLEL_ATTEMPTS_MADE=0
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        PARALLEL_ATTEMPTS_MADE="$attempt"
        printf 'service=%s action=check attempt=%s/%s type=%s\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$CURRENT_CHECK_TYPE"
        CHECK_RESULT_STATE=unavailable
        if perform_single_check "$index"; then
            CHECK_RESULT_STATE=healthy
            printf 'service=%s result=check-success attempt=%s/%s detail="%s"\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$(sanitize_detail "$CHECK_DETAIL")"
            return 0
        fi
        if [[ "$CHECK_RESULT_STATE" == degraded ]]; then
            printf 'service=%s result=check-degraded attempt=%s/%s detail="%s"\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$(sanitize_detail "$CHECK_DETAIL")"
        else
            printf 'service=%s result=check-failed attempt=%s/%s detail="%s"\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$(sanitize_detail "$CHECK_DETAIL")"
        fi
        (( attempt < attempts && retry_delay > 0 )) && sleep "$retry_delay"
    done
    return 1
}

parallel_timeout_for_service() {
    local index="$1" type timeout_value
    type="$(yaml_read ".services[$index].check.timeout | type")"
    if [[ "$type" == "!!null" ]]; then
        if [[ "$(yaml_read ".services[$index].check.type")" == clamav ]]; then printf 300; else printf '%s' "$PARALLEL_TIMEOUT"; fi
    else
        timeout_value="$(yaml_read ".services[$index].check.timeout")"; printf '%s' "$timeout_value"
    fi
}

write_parallel_result() {
    local result_file="$1" state="$2" detail="$3" http_status="$4" exit_code="$5" attempts="$6" duration="$7" http_total_ms="${8:-}" http_max_total_ms="${9:-}" temporary detail_encoded since_encoded
    temporary="${result_file}.tmp.${BASHPID}"
    detail_encoded="$(printf '%s' "$detail" | base64 | tr -d '\n')"
    since_encoded="$(printf '%s' "$THRESHOLD_SINCE" | base64 | tr -d '\n')"
    { printf 'state=%s\n' "$state"; printf 'detail_b64=%s\n' "$detail_encoded"; printf 'http_status=%s\n' "$http_status"; printf 'http_total_ms=%s\n' "$http_total_ms"; printf 'http_max_total_ms=%s\n' "$http_max_total_ms"; printf 'check_exit=%s\n' "$exit_code"; printf 'attempts=%s\n' "$attempts"; printf 'duration=%s\n' "$duration"; printf 'match_count=%s\n' "$MATCH_COUNT"; printf 'threshold=%s\n' "$THRESHOLD_VALUE"; printf 'comparator=%s\n' "$THRESHOLD_COMPARATOR"; printf 'since_b64=%s\n' "$since_encoded"; printf 'timestamp=%s\n' "$(date '+%s')"; } >"$temporary" && mv -f -- "$temporary" "$result_file"
}

_run_single_check_bg() {
    local index="$1" service_name="$2" result_file="$3" log_file="$4" timeout_value worker_pid timer_pid="" check_state=unavailable started_epoch
    # Check helpers use TEMP_DIRECTORY for curl and command output. Shadow it
    # for this worker so concurrent checks never share temporary files.
    local TEMP_DIRECTORY="${TEMP_DIRECTORY}/${service_name}.${BASHPID}"
    (
        # The parent owns the global lock; worker descendants (notably the
        # timeout sleeper) must not keep it open after the main run exits.
        exec 9>&-
        exec >"$log_file" 2>&1
        CURRENT_SERVICE="$service_name"; CHECK_CONFIG_PATH=".services[$index].check"; CURRENT_CHECK_TYPE="$(yaml_read "${CHECK_CONFIG_PATH}.type")"
        CHECK_DETAIL=""; CHECK_HTTP_STATUS=""; CHECK_HTTP_TOTAL_MS=""; CHECK_HTTP_MAX_TOTAL_MS=""; CHECK_RESULT_STATE=unavailable; CHECK_EXIT_CODE=""; MATCH_COUNT=""; THRESHOLD_VALUE=""; THRESHOLD_COMPARATOR=""; THRESHOLD_SINCE=""; PARALLEL_CHECK_MODE=1
        mkdir -p -- "$TEMP_DIRECTORY" || exit 1
        started_epoch="$(date '+%s')"
        timeout_value="$(parallel_timeout_for_service "$index")"; worker_pid="$BASHPID"
        if (( timeout_value > 0 )); then
            ( sleep "$timeout_value"; write_parallel_result "$result_file" unavailable "check timed out (parallel check timeout)" "" 124 "$PARALLEL_ATTEMPTS_MADE" "$timeout_value"; kill -KILL "$worker_pid" 2>/dev/null || true ) &
            timer_pid=$!
        fi
        check_with_retries_parallel "$index" && check_state=healthy || check_state="$CHECK_RESULT_STATE"
        [[ -z "$timer_pid" ]] || { kill "$timer_pid" 2>/dev/null || true; wait "$timer_pid" 2>/dev/null || true; }
        write_parallel_result "$result_file" "$check_state" "$CHECK_DETAIL" "$CHECK_HTTP_STATUS" "$CHECK_EXIT_CODE" "$PARALLEL_ATTEMPTS_MADE" "$(( $(date '+%s') - started_epoch ))" "$CHECK_HTTP_TOTAL_MS" "$CHECK_HTTP_MAX_TOTAL_MS"
        rm -rf -- "$TEMP_DIRECTORY"
    )
}

should_run_parallel() {
    local index="$1" value value_type
    (( PARALLEL_ENABLED == 1 )) || return 1
    value_type="$(yaml_read ".services[$index].parallel | type")"
    if [[ "$value_type" == "!!null" ]]; then
        value=true
    else
        value="$(yaml_read ".services[$index].parallel")"
    fi
    [[ "$value" == true ]]
}

collect_check_results() {
    local -n services_ref="$1"
    local service_name result_file log_file line key value detail_encoded since_encoded
    for service_name in "${services_ref[@]}"; do
        result_file="${TEMP_DIRECTORY}/${service_name}.result"
        PRELOADED_CHECK_STATE["$service_name"]=unavailable; PRELOADED_CHECK_DETAIL["$service_name"]="check process did not write result"
        PRELOADED_CHECK_HTTP_STATUS["$service_name"]=""; PRELOADED_CHECK_HTTP_TOTAL_MS["$service_name"]=""; PRELOADED_CHECK_HTTP_MAX_TOTAL_MS["$service_name"]=""; PRELOADED_CHECK_EXIT_CODE["$service_name"]=""; PRELOADED_CHECK_ATTEMPTS["$service_name"]=0; PRELOADED_CHECK_DURATION["$service_name"]=0
        PRELOADED_MATCH_COUNT["$service_name"]=""; PRELOADED_THRESHOLD_VALUE["$service_name"]=""; PRELOADED_THRESHOLD_COMPARATOR["$service_name"]=""; PRELOADED_THRESHOLD_SINCE["$service_name"]=""
        if [[ ! -r "$result_file" ]]; then log WARN "service=${service_name} phase=check mode=parallel result=missing temp_file_missing=true action=marked_unavailable"; continue; fi
        detail_encoded=""; since_encoded=""
        while IFS='=' read -r key value; do
            case "$key" in state) PRELOADED_CHECK_STATE["$service_name"]="$value" ;; detail_b64) detail_encoded="$value" ;; http_status) PRELOADED_CHECK_HTTP_STATUS["$service_name"]="$value" ;; http_total_ms) PRELOADED_CHECK_HTTP_TOTAL_MS["$service_name"]="$value" ;; http_max_total_ms) PRELOADED_CHECK_HTTP_MAX_TOTAL_MS["$service_name"]="$value" ;; check_exit) PRELOADED_CHECK_EXIT_CODE["$service_name"]="$value" ;; attempts) PRELOADED_CHECK_ATTEMPTS["$service_name"]="$value" ;; duration) PRELOADED_CHECK_DURATION["$service_name"]="$value" ;; match_count) PRELOADED_MATCH_COUNT["$service_name"]="$value" ;; threshold) PRELOADED_THRESHOLD_VALUE["$service_name"]="$value" ;; comparator) PRELOADED_THRESHOLD_COMPARATOR["$service_name"]="$value" ;; since_b64) since_encoded="$value" ;; esac
        done <"$result_file"
        [[ -z "$detail_encoded" ]] || PRELOADED_CHECK_DETAIL["$service_name"]="$(printf '%s' "$detail_encoded" | base64 --decode 2>/dev/null || true)"
        [[ -z "$since_encoded" ]] || PRELOADED_THRESHOLD_SINCE["$service_name"]="$(printf '%s' "$since_encoded" | base64 --decode 2>/dev/null || true)"
        [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy || "${PRELOADED_CHECK_STATE[$service_name]}" == unavailable || "${PRELOADED_CHECK_STATE[$service_name]}" == degraded ]] || { PRELOADED_CHECK_STATE["$service_name"]=unavailable; PRELOADED_CHECK_DETAIL["$service_name"]="invalid parallel check result"; }
        log INFO "service=${service_name} phase=check mode=parallel result=${PRELOADED_CHECK_STATE[$service_name]} detail=\"$(sanitize_detail "${PRELOADED_CHECK_DETAIL[$service_name]}")\""
        log_file="${TEMP_DIRECTORY}/${service_name}.log"
        if [[ -r "$log_file" ]]; then
            while IFS= read -r line; do
                log INFO "service=${service_name} phase=check mode=parallel worker_log=\"$(sanitize_detail "$line")\""
            done <"$log_file"
        fi
        rm -f -- "$result_file" "$log_file"
    done
}

run_checks_parallel() {
    local -n services_ref="$1"
    local service_name index result_file log_file started_ms completed_ms failed=0
    started_ms="$(now_milliseconds)"; log INFO "phase=check mode=parallel max_jobs=${PARALLEL_MAX_JOBS} services=${#services_ref[@]}"
    for service_name in "${services_ref[@]}"; do
        index="${SERVICE_INDEX[$service_name]}"
        while (( PARALLEL_MAX_JOBS > 0 && $(jobs -pr | wc -l) >= PARALLEL_MAX_JOBS )); do wait -n 2>/dev/null || true; done
        result_file="${TEMP_DIRECTORY}/${service_name}.result"; log_file="${TEMP_DIRECTORY}/${service_name}.log"
        _run_single_check_bg "$index" "$service_name" "$result_file" "$log_file" &
        log INFO "service=${service_name} phase=check mode=parallel pid=$!"
    done
    wait || true; collect_check_results "$1"
    for service_name in "${services_ref[@]}"; do [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy ]] || ((failed++)); done
    completed_ms="$(now_milliseconds)"; log INFO "phase=check mode=parallel completed=${#services_ref[@]} failed=${failed} duration_ms=$((completed_ms - started_ms))"
}

service_is_selected() {
    local service_name="$1"
    [[ -z "$ONLY_SERVICE" || "$service_name" == "$ONLY_SERVICE" ]] && return 0
    service_is_required_for "$ONLY_SERVICE" "$service_name"
}

use_preloaded_check_result() {
    local service_name="$1" attempts attempt
    [[ -n "${PRELOADED_CHECK_STATE[$service_name]+present}" ]] || return 1
    CHECK_DETAIL="${PRELOADED_CHECK_DETAIL[$service_name]}"
    CHECK_HTTP_STATUS="${PRELOADED_CHECK_HTTP_STATUS[$service_name]}"
    CHECK_HTTP_TOTAL_MS="${PRELOADED_CHECK_HTTP_TOTAL_MS[$service_name]:-}"
    CHECK_HTTP_MAX_TOTAL_MS="${PRELOADED_CHECK_HTTP_MAX_TOTAL_MS[$service_name]:-}"
    CHECK_RESULT_STATE="${PRELOADED_CHECK_STATE[$service_name]}"
    CHECK_EXIT_CODE="${PRELOADED_CHECK_EXIT_CODE[$service_name]}"
    MATCH_COUNT="${PRELOADED_MATCH_COUNT[$service_name]:-}"
    THRESHOLD_VALUE="${PRELOADED_THRESHOLD_VALUE[$service_name]:-}"
    THRESHOLD_COMPARATOR="${PRELOADED_THRESHOLD_COMPARATOR[$service_name]:-}"
    THRESHOLD_SINCE="${PRELOADED_THRESHOLD_SINCE[$service_name]:-}"
    HISTORY_CHECKED["$service_name"]=1
    HISTORY_CHECK_DURATION["$service_name"]="${PRELOADED_CHECK_DURATION[$service_name]:-0}"
    attempts="${PRELOADED_CHECK_ATTEMPTS[$service_name]:-0}"
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    for ((attempt = 0; attempt < attempts; attempt++)); do record_check_attempt "$service_name"; done
    record_http_timing "$service_name"
    if [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy ]]; then
        for ((attempt = 1; attempt < attempts; attempt++)); do increment_service_marker_number "$service_name" check-errors-total; done
        (( DRY_RUN == 1 )) || write_service_marker_number "$service_name" last-success "$(date '+%s')"
    elif [[ "${PRELOADED_CHECK_STATE[$service_name]}" != degraded ]]; then
        for ((attempt = 0; attempt < attempts; attempt++)); do increment_service_marker_number "$service_name" check-errors-total; done
    fi
    log INFO "service=${service_name} action=check result=${PRELOADED_CHECK_STATE[$service_name]} source=parallel detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
    [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy ]]
}

process_parallel_level() {
    local level="$1" service_name index enabled
    local -a checked_services=() level_services=() sequential_checks=() parallel_checks=()
    for service_name in "${SERVICE_ORDER[@]}"; do
        [[ "${SERVICE_LEVEL[$service_name]}" == "$level" ]] || continue; service_is_selected "$service_name" || continue
        level_services+=("$service_name"); index="${SERVICE_INDEX[$service_name]}"; enabled="$(yaml_read_true_default ".services[$index].enabled")"
        [[ "$enabled" == true ]] || continue
        required_dependency_is_unavailable "$service_name" >/dev/null && continue
        if ! evaluate_conditions "$index" "$service_name"; then
            CONDITION_SKIPPED["$service_name"]=1
            continue
        fi
        CONDITION_EVALUATED["$service_name"]=1
        [[ "$(yaml_read ".services[$index].health | type")" == '!!null' ]] || continue
        checked_services+=("$service_name")
        should_run_parallel "$index" && parallel_checks+=("$service_name") || sequential_checks+=("$service_name")
    done
    (( ${#parallel_checks[@]} == 0 )) || run_checks_parallel parallel_checks
    for service_name in "${sequential_checks[@]}"; do index="${SERVICE_INDEX[$service_name]}"; _run_single_check_bg "$index" "$service_name" "${TEMP_DIRECTORY}/${service_name}.result" "${TEMP_DIRECTORY}/${service_name}.log"; done
    (( ${#sequential_checks[@]} == 0 )) || collect_check_results sequential_checks
    for service_name in "${level_services[@]}"; do index="${SERVICE_INDEX[$service_name]}"; process_service "$index"; RESOLVED_STATE["$service_name"]="$PROCESS_RESULT"; history_capture_service "$service_name"; done
}

