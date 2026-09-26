validate_templates() {
    local templates_type template_count template_index template_name template_name_type template_type
    local reserved_field reserved_type warning service_count service_index service_name
    local template_reference template_reference_type mode mode_type template_exists

    templates_type="$(yaml_read '.templates | type' 2>/dev/null)" || die "Cannot read templates."
    case "$templates_type" in
        "!!null") template_count=0 ;;
        "!!map") template_count="$(yaml_read '.templates | length')" ;;
        *) die "templates must be a YAML map." ;;
    esac
    for ((template_index = 0; template_index < template_count; template_index++)); do
        template_name_type="$(yaml_read ".templates | to_entries[$template_index].key | type")"
        [[ "$template_name_type" == "!!str" ]] || die "Template names must be strings."
        template_name="$(yaml_read ".templates | to_entries[$template_index].key")"
        [[ "$template_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid template name: ${template_name}"
        template_type="$(yaml_read ".templates | to_entries[$template_index].value | type")"
        [[ "$template_type" == "!!map" ]] || die "Template '${template_name}' must be a YAML map."
        for reserved_field in name template template_mode; do
            reserved_type="$(yaml_read ".templates[\"${template_name}\"].${reserved_field} | type")"
            if [[ "$reserved_type" != "!!null" ]]; then
                warning="template=${template_name} warning=template_contains_${reserved_field} ignored=true"
                TEMPLATE_WARNING_LOG+=("$warning")
                bootstrap_log WARN "$warning"
            fi
        done
    done

    service_count="$(yaml_read '.services | length')"
    for ((service_index = 0; service_index < service_count; service_index++)); do
        service_name="$(yaml_read ".services[$service_index].name // \"index-${service_index}\"")"
        template_reference_type="$(yaml_read ".services[$service_index].template | type")"
        [[ "$template_reference_type" == "!!null" ]] && continue
        [[ "$template_reference_type" == "!!str" ]] || die "Service '${service_name}': template must be a string."
        template_reference="$(yaml_read ".services[$service_index].template")"
        [[ "$template_reference" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Service '${service_name}': template must be a valid template name."
        [[ "$templates_type" == "!!map" ]] || die "result=config-error reason=missing_template service=${service_name} template=${template_reference}"
        template_exists="$(yaml_read ".templates | has(\"${template_reference}\")")"
        [[ "$template_exists" == true ]] || die "result=config-error reason=missing_template service=${service_name} template=${template_reference}"
        mode_type="$(yaml_read ".services[$service_index].template_mode | type")"
        [[ "$mode_type" == "!!null" || "$mode_type" == "!!str" ]] || die "Service '${service_name}': template_mode must be deep or shallow."
        mode="$(yaml_read ".services[$service_index].template_mode // \"deep\"")"
        [[ "$mode" == deep || "$mode" == shallow ]] || die "result=config-error reason=invalid_template_mode service=${service_name} mode=${mode}"
    done
}

expand_templates() {
    local service_count service_index service_name template_name mode fields_inherited merge_expression

    [[ "$(yaml_read '.templates | type')" == "!!map" ]] || return 0
    EXPANDED_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/service-watchdog.templates.XXXXXX.yaml")" || die "Cannot create expanded template configuration."
    yq eval '.' "$CONFIG_FILE" >"$EXPANDED_CONFIG_FILE" || die "Cannot expand templates."
    service_count="$(yq eval -r '.services | length' "$EXPANDED_CONFIG_FILE")"
    for ((service_index = 0; service_index < service_count; service_index++)); do
        template_name="$(yq eval -r ".services[$service_index].template // \"\"" "$EXPANDED_CONFIG_FILE")"
        [[ -n "$template_name" ]] || continue
        service_name="$(yq eval -r ".services[$service_index].name" "$EXPANDED_CONFIG_FILE")"
        mode="$(yq eval -r ".services[$service_index].template_mode // \"deep\"" "$EXPANDED_CONFIG_FILE")"
        fields_inherited="$(yq eval -r "((.templates[\"${template_name}\"] | del(.name, .template, .template_mode) | keys) - (.services[$service_index] | del(.template, .template_mode) | keys)) | length" "$EXPANDED_CONFIG_FILE")"
        case "$mode" in
            deep) merge_expression="(.templates[\"${template_name}\"] | del(.name, .template, .template_mode)) * (.services[$service_index] | del(.template, .template_mode))" ;;
            shallow) merge_expression="(.templates[\"${template_name}\"] | del(.name, .template, .template_mode)) + (.services[$service_index] | del(.template, .template_mode))" ;;
            *) die "result=config-error reason=invalid_template_mode service=${service_name} mode=${mode}" ;;
        esac
        yq eval -i ".services[$service_index] = (${merge_expression})" "$EXPANDED_CONFIG_FILE" || die "Cannot merge template '${template_name}' for service '${service_name}'."
        TEMPLATE_EXPANSION_LOG+=("template=${template_name} service=${service_name} mode=${mode} result=merged fields_inherited=${fields_inherited}")
    done
    yq eval -i 'del(.templates)' "$EXPANDED_CONFIG_FILE" || die "Cannot finalize expanded template configuration."
    CONFIG_FILE="$EXPANDED_CONFIG_FILE"
}

# Status must validate the same merged configuration without writing a temp file.
expand_templates_readonly() {
    local service_count service_index service_name template_name mode fields_inherited merge_expression
    STATUS_CONFIG_CONTENT="$(yq eval '.' "$CONFIG_FILE")" || die 'Cannot read configuration for status.'
    [[ "$(yaml_read '.templates | type')" == '!!map' ]] || return 0
    service_count="$(yaml_read '.services | length')"
    for ((service_index = 0; service_index < service_count; service_index++)); do
        template_name="$(yaml_read ".services[$service_index].template // \"\"")"
        [[ -n "$template_name" ]] || continue
        service_name="$(yaml_read ".services[$service_index].name")"
        mode="$(yaml_read ".services[$service_index].template_mode // \"deep\"")"
        fields_inherited="$(yaml_read "((.templates[\"${template_name}\"] | del(.name, .template, .template_mode) | keys) - (.services[$service_index] | del(.template, .template_mode) | keys)) | length")"
        case "$mode" in
            deep) merge_expression="(.templates[\"${template_name}\"] | del(.name, .template, .template_mode)) * (.services[$service_index] | del(.template, .template_mode))" ;;
            shallow) merge_expression="(.templates[\"${template_name}\"] | del(.name, .template, .template_mode)) + (.services[$service_index] | del(.template, .template_mode))" ;;
            *) die "result=config-error reason=invalid_template_mode service=${service_name} mode=${mode}" ;;
        esac
        STATUS_CONFIG_CONTENT="$(printf '%s\n' "$STATUS_CONFIG_CONTENT" | yq eval ".services[$service_index] = (${merge_expression})" -)" ||
            die "Cannot merge template '${template_name}' for status."
        TEMPLATE_EXPANSION_LOG+=("template=${template_name} service=${service_name} mode=${mode} result=merged fields_inherited=${fields_inherited}")
    done
    STATUS_CONFIG_CONTENT="$(printf '%s\n' "$STATUS_CONFIG_CONTENT" | yq eval 'del(.templates)' -)" ||
        die 'Cannot finalize template expansion for status.'
}

log_template_expansions() {
    local entry
    for entry in "${TEMPLATE_WARNING_LOG[@]}"; do
        log WARN "$entry"
    done
    for entry in "${TEMPLATE_EXPANSION_LOG[@]}"; do
        log INFO "$entry"
    done
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_non_negative_number() {
    [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

history_validate_config() {
    local section_type value value_type count index field ancestor default_value
    local -A seen=()
    section_type="$(yaml_read '.history | type')"
    [[ "$section_type" == '!!null' || "$section_type" == '!!map' ]] || die 'history must be a map.'
    value="$(yaml_read '.history.enabled // false')"
    [[ "$value" == true || "$value" == false ]] || die 'history.enabled must be true or false.'
    [[ "$value" == true ]] && HISTORY_ENABLED=1
    HISTORY_STORAGE="$(yaml_read '.history.storage // "jsonl"')"
    [[ "$HISTORY_STORAGE" == jsonl || "$HISTORY_STORAGE" == sqlite ]] || die 'history.storage must be jsonl or sqlite.'
    HISTORY_PATH="$(yaml_read '.history.path // ""')"
    if [[ -z "$HISTORY_PATH" ]]; then
        if [[ "$HISTORY_STORAGE" == jsonl ]]; then HISTORY_PATH="${STATE_DIRECTORY}/history"; else HISTORY_PATH="${STATE_DIRECTORY}/history.db"; fi
    fi
    [[ "$HISTORY_PATH" == /* ]] || die 'history.path must be an absolute path.'
    HISTORY_ROTATION_MODE="$(yaml_read '.history.rotation.mode // "daily"')"
    [[ "$HISTORY_ROTATION_MODE" == daily || "$HISTORY_ROTATION_MODE" == single ]] || die 'history.rotation.mode must be daily or single.'
    for field in max_age_days max_records; do
        if [[ "$field" == max_age_days ]]; then default_value=30; else default_value=0; fi
        value="$(yaml_read ".history.rotation.${field} // ${default_value}")"
        is_non_negative_integer "$value" || die "history.rotation.${field} must be a non-negative integer."
        if [[ "$field" == max_age_days ]]; then HISTORY_MAX_AGE_DAYS="$((10#$value))"; else HISTORY_MAX_RECORDS="$((10#$value))"; fi
    done
    value="$(yaml_read '.history.reports.trend_dots // 60')"
    is_positive_integer "$value" || die 'history.reports.trend_dots must be a positive integer.'
    (( 10#$value <= 1000 )) || die 'history.reports.trend_dots must not exceed 1000.'
    HISTORY_TREND_DOTS="$((10#$value))"
    value_type="$(yaml_read '.history.fields | type')"
    if [[ "$value_type" != '!!null' ]]; then
        [[ "$value_type" == '!!seq' ]] || die 'history.fields must be an array.'
        count="$(yaml_read '.history.fields | length')"
        (( count > 0 )) || die 'history.fields must not be empty.'
        HISTORY_FIELDS=()
        for ((index = 0; index < count; index++)); do
            field="$(yaml_read ".history.fields[$index]")"
            case "$field" in timestamp|node_id|service|state|check_type|detail|http_status|check_exit|action_status|duration_sec) ;; *) die "history.fields[$index] is not a supported field." ;; esac
            [[ -z "${seen[$field]:-}" ]] || die "history.fields[$index] duplicates ${field}."
            seen["$field"]=1
            HISTORY_FIELDS+=("$field")
        done
        for field in timestamp service state; do [[ -n "${seen[$field]:-}" ]] || die "history.fields must include ${field} for reports."; done
    else
        HISTORY_FIELDS=(timestamp node_id service state check_type detail http_status check_exit action_status duration_sec)
    fi
    if (( HISTORY_ENABLED == 1 )) || [[ "$COMMAND_MODE" == history ]]; then
        if [[ "$HISTORY_STORAGE" == sqlite ]]; then
            command -v sqlite3 >/dev/null 2>&1 || die 'history.storage=sqlite requires sqlite3 in PATH.'
            [[ ! -d "$HISTORY_PATH" ]] || die 'history.path must be a SQLite database file, not a directory.'
            ancestor="$(dirname -- "$HISTORY_PATH")"
        else
            [[ ! -e "$HISTORY_PATH" || -d "$HISTORY_PATH" ]] || die 'history.path must be a directory for jsonl.'
            ancestor="$HISTORY_PATH"
        fi
        if [[ "$COMMAND_MODE" == history || "$COMMAND_MODE" == status ]]; then
            [[ ! -e "$HISTORY_PATH" || -r "$HISTORY_PATH" ]] || die 'history.path cannot be read.'
        else
            while [[ ! -e "$ancestor" ]]; do ancestor="$(dirname -- "$ancestor")"; done
            [[ -d "$ancestor" && -w "$ancestor" ]] || die 'history.path cannot be created or written.'
        fi
    fi
}

validate_string() {
    local expression="$1"
    local description="$2"
    local value_type
    value_type="$(yaml_read "${expression} | type" 2>/dev/null)" ||
        die "Cannot read ${description}."
    [[ "$value_type" == "!!str" ]] || die "${description} must be a string."
}

validate_command_sequence() {
    local expression="$1"
    local description="$2"
    local allow_empty="${3:-false}"
    local sequence_type sequence_count command_index command_type command_length
    local argument_index argument_type working_directory_type timeout_value

    sequence_type="$(yaml_read "${expression} | type" 2>/dev/null)" ||
        die "Cannot read ${description}."
    [[ "$sequence_type" == "!!seq" ]] || die "${description} must be a YAML array."

    sequence_count="$(yaml_read "${expression} | length")"
    if (( sequence_count == 0 )); then
        [[ "$allow_empty" == "true" ]] || die "${description} must not be empty."
        return 0
    fi

    for ((command_index = 0; command_index < sequence_count; command_index++)); do
        command_type="$(yaml_read "${expression}[$command_index].command | type")"
        [[ "$command_type" == "!!seq" ]] ||
            die "${description}[$command_index].command must be an array."
        command_length="$(yaml_read "${expression}[$command_index].command | length")"
        (( command_length > 0 )) ||
            die "${description}[$command_index].command must not be empty."

        for ((argument_index = 0; argument_index < command_length; argument_index++)); do
            argument_type="$(yaml_read "${expression}[$command_index].command[$argument_index] | type")"
            case "$argument_type" in
                "!!str"|"!!int"|"!!float"|"!!bool") ;;
                *) die "${description}[$command_index].command[$argument_index] must be scalar." ;;
            esac
        done

        working_directory_type="$(yaml_read "${expression}[$command_index].working_directory | type")"
        if [[ "$working_directory_type" != "!!null" ]]; then
            validate_string "${expression}[$command_index].working_directory" \
                "${description}[$command_index].working_directory"
            [[ -d "$(yaml_read "${expression}[$command_index].working_directory")" ]] ||
                die "${description}[$command_index].working_directory does not exist."
        fi

        timeout_value="$(yaml_read "${expression}[$command_index].timeout // ${DEFAULT_ACTION_TIMEOUT}")"
        is_positive_integer "$timeout_value" ||
            die "${description}[$command_index].timeout must be a positive integer."
    done
}

security_policy_check_command() {
    local path_name canonical allow_count allow_index argument_index candidate_count allowed_arg
    local -n command_ref="$1"
    [[ "$(yaml_read '.security.remediation_policy.mode // "legacy"')" == enforce ]] || return 0
    path_name="${command_ref[0]}"
    [[ "$path_name" == /* && -f "$path_name" && -x "$path_name" ]] || return 1
    canonical="$(realpath -e -- "$path_name" 2>/dev/null)" || return 1
    [[ "$canonical" == "$path_name" ]] || return 1
    # Scripts can hide shell evaluation behind an innocuous executable name.
    [[ "$(head -c 2 -- "$path_name" 2>/dev/null)" != '#!' ]] || return 1
    case "${path_name##*/}" in
        sh|bash|dash|zsh|ksh|env|sudo|su|doas|python|python[0-9]*|perl|ruby|node|php|busybox|find|xargs) return 1 ;;
    esac
    allow_count="$(yaml_read '.security.remediation_policy.allowed_commands | length')"
    for ((allow_index = 0; allow_index < allow_count; allow_index++)); do
        candidate_count="$(yaml_read ".security.remediation_policy.allowed_commands[$allow_index].command | length")"
        (( candidate_count == ${#command_ref[@]} )) || continue
        for ((argument_index = 0; argument_index < candidate_count; argument_index++)); do
            allowed_arg="$(yaml_read ".security.remediation_policy.allowed_commands[$allow_index].command[$argument_index]")"
            [[ "$allowed_arg" == "${command_ref[$argument_index]}" ]] || break
        done
        (( argument_index == candidate_count )) && return 0
    done
    return 1
}

validate_security_policy() {
    local mode policy_type count index service_count command_count expression description
    local -a candidate=()
    policy_type="$(yaml_read '.security.remediation_policy | type')"
    [[ "$policy_type" == '!!null' || "$policy_type" == '!!map' ]] || die 'security.remediation_policy must be a map.'
    mode="$(yaml_read '.security.remediation_policy.mode // "legacy"')"
    [[ "$mode" == legacy || "$mode" == enforce ]] || die 'security.remediation_policy.mode must be legacy or enforce.'
    [[ "$mode" == enforce ]] || return 0
    require_command realpath
    require_command head
    validate_command_sequence '.security.remediation_policy.allowed_commands' 'security.remediation_policy.allowed_commands'
    count="$(yaml_read '.security.remediation_policy.allowed_commands | length')"
    for ((index = 0; index < count; index++)); do
        load_command ".security.remediation_policy.allowed_commands[$index].command" candidate
        security_policy_check_command candidate ||
            die "security.remediation_policy.allowed_commands[$index].command is unsafe or not an exact allowlist entry."
    done
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        for description in actions.commands escalation.actions.commands; do
            expression=".services[$index].${description}"
            command_count="$(yaml_read "${expression} // [] | length")"
            for ((count = 0; count < command_count; count++)); do
                load_command "${expression}[$count].command" candidate
                security_policy_check_command candidate ||
                    die "${expression}[$count].command is not allowed by security.remediation_policy."
            done
        done
    done
}

validate_email_configuration() {
    local enabled value value_type password_env password recipients_type
    local recipient recipient_index timeout_value

    enabled="$(yaml_read '.notifications.email.enabled // false')"
    case "$enabled" in
        false) return 0 ;;
        true) ;;
        *) die "notifications.email.enabled must be true or false." ;;
    esac

    validate_string '.notifications.email.smtp.url' 'notifications.email.smtp.url'
    validate_string '.notifications.email.smtp.from' 'notifications.email.smtp.from'
    validate_string '.notifications.email.failure.subject' 'notifications.email.failure.subject'
    validate_string '.notifications.email.failure.body' 'notifications.email.failure.body'
    validate_string '.notifications.email.recovery.subject' 'notifications.email.recovery.subject'
    validate_string '.notifications.email.recovery.body' 'notifications.email.recovery.body'

    value="$(yaml_read '.notifications.email.smtp.url')"
    [[ "$value" =~ ^smtps?://[^[:space:]]+$ ]] ||
        die "notifications.email.smtp.url must start with smtp:// or smtps:// and contain no spaces."
    value="$(yaml_read '.notifications.email.smtp.from')"
    [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ||
        die "notifications.email.smtp.from must be one email address."

    for value in failure recovery; do
        value_type="$(yaml_read ".notifications.email.${value}.subject")"
        [[ "$value_type" != *$'\n'* && "$value_type" != *$'\r'* ]] ||
            die "notifications.email.${value}.subject must be a single line."
    done

    value_type="$(yaml_read '.notifications.email.smtp.username | type')"
    [[ "$value_type" == "!!null" ]] ||
        validate_string '.notifications.email.smtp.username' 'notifications.email.smtp.username'
    value_type="$(yaml_read '.notifications.email.smtp.password_env | type')"
    [[ "$value_type" == "!!null" ]] ||
        validate_string '.notifications.email.smtp.password_env' 'notifications.email.smtp.password_env'
    value_type="$(yaml_read '.notifications.email.smtp.password | type')"
    [[ "$value_type" == "!!null" ]] ||
        validate_string '.notifications.email.smtp.password' 'notifications.email.smtp.password'

    password_env="$(yaml_read '.notifications.email.smtp.password_env // ""')"
    password="$(yaml_read '.notifications.email.smtp.password // ""')"
    value="$(yaml_read '.notifications.email.smtp.username // ""')"
    [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] ||
        die 'notifications.email.smtp.username must not contain a carriage return or newline.'
    [[ "$password" != *$'\r'* && "$password" != *$'\n'* ]] ||
        die 'notifications.email.smtp.password must not contain a carriage return or newline.'
    [[ -z "$password_env" || -z "$password" ]] ||
        die "Use only one of notifications.email.smtp.password_env or password."
    if [[ -n "$password_env" ]]; then
        [[ "$password_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            die "notifications.email.smtp.password_env is not a valid environment variable name."
    fi

    value_type="$(yaml_read_true_default '.notifications.email.smtp.tls_required')"
    [[ "$value_type" == true || "$value_type" == false ]] ||
        die "notifications.email.smtp.tls_required must be true or false."
    value_type="$(yaml_read '.notifications.email.smtp.insecure_skip_verify // false')"
    [[ "$value_type" == true || "$value_type" == false ]] ||
        die "notifications.email.smtp.insecure_skip_verify must be true or false."

    timeout_value="$(yaml_read '.notifications.email.smtp.timeout // 30')"
    if ! is_positive_integer "$timeout_value" || (( 10#$timeout_value > 60 )); then
        die "notifications.email.smtp.timeout must be from 1 through 60 seconds."
    fi

    recipients_type="$(yaml_read '.notifications.email.recipients | type')"
    [[ "$recipients_type" == "!!seq" ]] ||
        die "notifications.email.recipients must be a YAML array."
    EMAIL_RECIPIENTS_COUNT="$(yaml_read '.notifications.email.recipients | length')"
    (( EMAIL_RECIPIENTS_COUNT > 0 )) ||
        die "notifications.email.recipients must not be empty."
    for ((recipient_index = 0; recipient_index < EMAIL_RECIPIENTS_COUNT; recipient_index++)); do
        validate_string ".notifications.email.recipients[$recipient_index]" \
            "notifications.email.recipients[$recipient_index]"
        recipient="$(yaml_read ".notifications.email.recipients[$recipient_index]")"
        [[ "$recipient" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ||
            die "Invalid email address in notifications.email.recipients[$recipient_index]."
    done
}

validate_webhook_configuration() {
    local webhooks_type webhook enabled value value_type env_name priority

    webhooks_type="$(yaml_read '.notifications.webhooks | type')"
    [[ "$webhooks_type" == "!!null" ]] && return 0
    [[ "$webhooks_type" == "!!map" ]] || die "notifications.webhooks must be a YAML map."

    for webhook in telegram discord slack ntfy; do
        value_type="$(yaml_read ".notifications.webhooks.${webhook} | type")"
        [[ "$value_type" == "!!null" ]] && continue
        [[ "$value_type" == "!!map" ]] || die "notifications.webhooks.${webhook} must be a YAML map."
        enabled="$(yaml_read ".notifications.webhooks.${webhook}.enabled // false")"
        [[ "$enabled" == true || "$enabled" == false ]] ||
            die "notifications.webhooks.${webhook}.enabled must be true or false."
        [[ "$enabled" == true ]] || continue

        for value in failure recovery escalation circuit_open circuit_close flapping; do
            value_type="$(yaml_read ".notifications.webhooks.${webhook}.template.${value} | type")"
            [[ "$value_type" == "!!null" ]] ||
                validate_string ".notifications.webhooks.${webhook}.template.${value}" \
                    "notifications.webhooks.${webhook}.template.${value}"
        done

        case "$webhook" in
            telegram)
                validate_string '.notifications.webhooks.telegram.bot_token_env' 'notifications.webhooks.telegram.bot_token_env'
                validate_string '.notifications.webhooks.telegram.chat_id' 'notifications.webhooks.telegram.chat_id'
                env_name="$(yaml_read '.notifications.webhooks.telegram.bot_token_env')"
                value="$(yaml_read '.notifications.webhooks.telegram.chat_id')"
                [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "notifications.webhooks.telegram.bot_token_env is not a valid environment variable name."
                [[ -n "$value" ]] || die "notifications.webhooks.telegram.chat_id must not be empty."
                value="$(yaml_read '.notifications.webhooks.telegram.thread_id // ""')"
                [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] ||
                    die "notifications.webhooks.telegram.thread_id must be a positive integer."
                ;;
            discord|slack)
                validate_string ".notifications.webhooks.${webhook}.webhook_url_env" \
                    "notifications.webhooks.${webhook}.webhook_url_env"
                env_name="$(yaml_read ".notifications.webhooks.${webhook}.webhook_url_env")"
                [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "notifications.webhooks.${webhook}.webhook_url_env is not a valid environment variable name."
                ;;
            ntfy)
                validate_string '.notifications.webhooks.ntfy.url' 'notifications.webhooks.ntfy.url'
                value="$(yaml_read '.notifications.webhooks.ntfy.url')"
                [[ "$value" =~ ^https?://[^[:space:]]+$ ]] ||
                    die "notifications.webhooks.ntfy.url must be an HTTP(S) URL without spaces."
                env_name="$(yaml_read '.notifications.webhooks.ntfy.token_env // ""')"
                [[ -z "$env_name" || "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "notifications.webhooks.ntfy.token_env is not a valid environment variable name."
                priority="$(yaml_read '.notifications.webhooks.ntfy.priority // "default"')"
                [[ "$priority" =~ ^[1-5]$ || "$priority" =~ ^(min|low|default|high|urgent|max)$ ]] ||
                    die "notifications.webhooks.ntfy.priority must be 1-5, min, low, default, high, urgent, or max."
                ;;
        esac

        # Delivery credentials are only needed for a real notification.
    done
}

validate_maintenance_configuration() {
    local index="$1" service_name="$2" maintenance_type timezone windows_type count window
    local days time start end day normalized_day

    maintenance_type="$(yaml_read ".services[$index].maintenance | type")"
    [[ "$maintenance_type" == "!!null" ]] && return 0
    [[ "$maintenance_type" == "!!map" ]] || die "Service '${service_name}': maintenance must be a YAML map."
    timezone="$(yaml_read ".services[$index].maintenance.timezone // \"\"")"
    if [[ -n "$timezone" ]]; then
        [[ "$timezone" != *[[:space:]]* ]] || die "Service '${service_name}': maintenance.timezone must not contain spaces."
        TZ="$timezone" date '+%H:%M' >/dev/null 2>&1 ||
            die "Service '${service_name}': maintenance.timezone is invalid: ${timezone}"
        [[ "$timezone" == UTC || -r "/usr/share/zoneinfo/${timezone}" ]] ||
            die "Service '${service_name}': maintenance.timezone is not an installed IANA time zone: ${timezone}"
    fi
    windows_type="$(yaml_read ".services[$index].maintenance.windows | type")"
    [[ "$windows_type" == "!!seq" ]] || die "Service '${service_name}': maintenance.windows must be a YAML array."
    count="$(yaml_read ".services[$index].maintenance.windows | length")"
    for ((window = 0; window < count; window++)); do
        validate_string ".services[$index].maintenance.windows[$window].days" \
            "Service '${service_name}': maintenance.windows[$window].days"
        validate_string ".services[$index].maintenance.windows[$window].time" \
            "Service '${service_name}': maintenance.windows[$window].time"
        days="$(yaml_read ".services[$index].maintenance.windows[$window].days")"
        time="$(yaml_read ".services[$index].maintenance.windows[$window].time")"
        [[ "$time" =~ ^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$ ]] ||
            die "Service '${service_name}': maintenance.windows[$window].time must use HH:MM-HH:MM."
        start="${time%-*}"; end="${time#*-}"
        [[ "${start%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${start#*:}" =~ ^[0-5][0-9]$ &&
           "${end%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${end#*:}" =~ ^[0-5][0-9]$ &&
           "$start" < "$end" ]] ||
            die "Service '${service_name}': maintenance.windows[$window].time must be a same-day interval with start before end."
        [[ -n "$days" ]] || die "Service '${service_name}': maintenance.windows[$window].days must not be empty."
        [[ "$days" == "*" ]] && continue
        IFS=',' read -r -a day_list <<<"$days"
        for day in "${day_list[@]}"; do
            normalized_day="${day,,}"
            case "$normalized_day" in mon|tue|wed|thu|fri|sat|sun) ;; *)
                die "services[$index].maintenance.windows[$window].days contains invalid day '${day}'." ;;
            esac
        done
    done
}

validate_only_if_configuration() {
    local index="$1" service_name="$2" conditions_type condition_count condition type value value_type
    local argument_count argument_index exit_count exit_index days time start end day normalized_day timezone
    local threshold_count
    local -a condition_days=()

    conditions_type="$(yaml_read ".services[$index].only_if | type")"
    [[ "$conditions_type" == "!!null" ]] && return 0
    [[ "$conditions_type" == "!!seq" ]] || die "Service '${service_name}': only_if must be a YAML array."
    condition_count="$(yaml_read ".services[$index].only_if | length")"
    for ((condition = 0; condition < condition_count; condition++)); do
        validate_string ".services[$index].only_if[$condition].type" "Service '${service_name}': only_if[$condition].type"
        type="$(yaml_read ".services[$index].only_if[$condition].type")"
        value="$(yaml_read ".services[$index].only_if[$condition].invert // false")"
        [[ "$value" == true || "$value" == false ]] || die "Service '${service_name}': only_if[$condition].invert must be true or false."
        case "$type" in
            command)
                value_type="$(yaml_read ".services[$index].only_if[$condition].command | type")"
                [[ "$value_type" == "!!seq" ]] || die "Service '${service_name}': only_if[$condition].command must be an array."
                argument_count="$(yaml_read ".services[$index].only_if[$condition].command | length")"
                (( argument_count > 0 )) || die "Service '${service_name}': only_if[$condition].command must not be empty."
                for ((argument_index = 0; argument_index < argument_count; argument_index++)); do
                    value_type="$(yaml_read ".services[$index].only_if[$condition].command[$argument_index] | type")"
                    case "$value_type" in "!!str"|"!!int"|"!!float"|"!!bool") ;; *)
                        die "Service '${service_name}': only_if[$condition].command[$argument_index] must be scalar." ;;
                    esac
                done
                value="$(yaml_read ".services[$index].only_if[$condition].timeout // 10")"
                is_positive_integer "$value" || die "Service '${service_name}': only_if[$condition].timeout must be a positive integer."
                value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code | type")"
                case "$value_type" in
                    "!!null") ;;
                    "!!int")
                        value="$(yaml_read ".services[$index].only_if[$condition].exit_code")"
                        if ! is_non_negative_integer "$value" || (( 10#$value > 255 )); then
                            die "Service '${service_name}': only_if[$condition].exit_code must be from 0 through 255."
                        fi
                        ;;
                    "!!seq")
                        exit_count="$(yaml_read ".services[$index].only_if[$condition].exit_code | length")"
                        (( exit_count > 0 )) || die "Service '${service_name}': only_if[$condition].exit_code must not be empty."
                        for ((exit_index = 0; exit_index < exit_count; exit_index++)); do
                            value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code[$exit_index] | type")"
                            [[ "$value_type" == "!!int" ]] || die "Service '${service_name}': only_if[$condition].exit_code[$exit_index] must be an integer."
                            value="$(yaml_read ".services[$index].only_if[$condition].exit_code[$exit_index]")"
                            if ! is_non_negative_integer "$value" || (( 10#$value > 255 )); then
                                die "Service '${service_name}': only_if[$condition].exit_code[$exit_index] must be from 0 through 255."
                            fi
                        done
                        ;;
                    *) die "Service '${service_name}': only_if[$condition].exit_code must be an integer or array." ;;
                esac
                ;;
            file_exists)
                validate_string ".services[$index].only_if[$condition].path" "Service '${service_name}': only_if[$condition].path"
                value="$(yaml_read ".services[$index].only_if[$condition].path")"
                [[ "$value" == /* ]] || die "Service '${service_name}': only_if[$condition].path must be absolute."
                ;;
            time_window)
                validate_string ".services[$index].only_if[$condition].days" "Service '${service_name}': only_if[$condition].days"
                validate_string ".services[$index].only_if[$condition].time" "Service '${service_name}': only_if[$condition].time"
                days="$(yaml_read ".services[$index].only_if[$condition].days")"
                time="$(yaml_read ".services[$index].only_if[$condition].time")"
                [[ "$time" =~ ^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$ ]] || die "Service '${service_name}': only_if[$condition].time must use HH:MM-HH:MM."
                start="${time%-*}"; end="${time#*-}"
                [[ "${start%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${start#*:}" =~ ^[0-5][0-9]$ && "${end%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${end#*:}" =~ ^[0-5][0-9]$ && "$start" < "$end" ]] || die "Service '${service_name}': only_if[$condition].time must be a same-day interval with start before end."
                [[ -n "$days" ]] || die "Service '${service_name}': only_if[$condition].days must not be empty."
                if [[ "$days" != "*" ]]; then
                    IFS=',' read -r -a condition_days <<<"$days"
                    for day in "${condition_days[@]}"; do
                        normalized_day="${day,,}"
                        case "$normalized_day" in mon|tue|wed|thu|fri|sat|sun) ;; *) die "services[$index].only_if[$condition].days contains invalid day '${day}'." ;; esac
                    done
                fi
                value_type="$(yaml_read ".services[$index].only_if[$condition].timezone | type")"
                if [[ "$value_type" != "!!null" ]]; then
                    validate_string ".services[$index].only_if[$condition].timezone" "Service '${service_name}': only_if[$condition].timezone"
                    timezone="$(yaml_read ".services[$index].only_if[$condition].timezone")"
                    [[ "$timezone" != *[[:space:]]* ]] || die "Service '${service_name}': only_if[$condition].timezone must not contain spaces."
                    TZ="$timezone" date '+%H:%M' >/dev/null 2>&1 || die "Service '${service_name}': only_if[$condition].timezone is invalid: ${timezone}"
                    [[ "$timezone" == UTC || -r "/usr/share/zoneinfo/${timezone}" ]] || die "Service '${service_name}': only_if[$condition].timezone is not an installed IANA time zone: ${timezone}"
                fi
                ;;
            load_average)
                threshold_count=0
                for value in max_1min max_5min max_15min; do
                    value_type="$(yaml_read ".services[$index].only_if[$condition].${value} | type")"
                    [[ "$value_type" == "!!null" ]] && continue
                    [[ "$value_type" == "!!int" || "$value_type" == "!!float" ]] || die "Service '${service_name}': only_if[$condition].${value} must be a number."
                    type="$(yaml_read ".services[$index].only_if[$condition].${value}")"
                    is_non_negative_number "$type" || die "Service '${service_name}': only_if[$condition].${value} must be non-negative."
                    ((threshold_count++))
                done
                (( threshold_count > 0 )) || die "Service '${service_name}': only_if[$condition].load_average needs at least one maximum."
                ;;
            filesystem)
                validate_string ".services[$index].only_if[$condition].path" "Service '${service_name}': only_if[$condition].path"
                value="$(yaml_read ".services[$index].only_if[$condition].path")"
                [[ "$value" == /* ]] || die "Service '${service_name}': only_if[$condition].path must be absolute."
                threshold_count=0
                for value in min_free_gb min_free_percent; do
                    value_type="$(yaml_read ".services[$index].only_if[$condition].${value} | type")"
                    [[ "$value_type" == "!!null" ]] && continue
                    [[ "$value_type" == "!!int" || "$value_type" == "!!float" ]] || die "Service '${service_name}': only_if[$condition].${value} must be a number."
                    type="$(yaml_read ".services[$index].only_if[$condition].${value}")"
                    is_non_negative_number "$type" || die "Service '${service_name}': only_if[$condition].${value} must be non-negative."
                    if [[ "$value" == min_free_percent ]] && ! awk -v threshold="$type" 'BEGIN { exit !(threshold <= 100) }'; then
                        die "Service '${service_name}': only_if[$condition].min_free_percent must not exceed 100."
                    fi
                    ((threshold_count++))
                done
                (( threshold_count > 0 )) || die "Service '${service_name}': only_if[$condition].filesystem needs min_free_gb or min_free_percent."
                ;;
            *) die "Service '${service_name}': only_if[$condition].type must be command, file_exists, time_window, load_average, or filesystem." ;;
        esac
    done
}

validate_escalation_configuration() {
    local index="$1" service_name="$2" escalation_type enabled value value_type hooks_type field levels_count level threshold_count

    escalation_type="$(yaml_read ".services[$index].escalation | type")"
    [[ "$escalation_type" == "!!null" ]] && return 0
    [[ "$escalation_type" == "!!map" ]] || die "Service '${service_name}': escalation must be a YAML map."
    enabled="$(yaml_read ".services[$index].escalation.enabled // false")"
    [[ "$enabled" == true || "$enabled" == false ]] ||
        die "Service '${service_name}': escalation.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    threshold_count=0
    for field in after_consecutive_unavailable after_duration_seconds after_failed_remediations; do
        value_type="$(yaml_read ".services[$index].escalation.${field} | type")"
        [[ "$value_type" == '!!null' ]] && continue
        value="$(yaml_read ".services[$index].escalation.${field}")"
        is_positive_integer "$value" || die "services[$index].escalation.${field} must be a positive integer."
        ((threshold_count++))
    done
    value_type="$(yaml_read ".services[$index].escalation.levels | type")"
    [[ "$value_type" == '!!null' || "$value_type" == '!!seq' ]] || die "services[$index].escalation.levels must be an array."
    levels_count="$(yaml_read ".services[$index].escalation.levels // [] | length")"
    (( threshold_count > 0 || levels_count > 0 )) || die "services[$index].escalation needs at least one threshold or level."
    for ((level = 0; level < levels_count; level++)); do
        threshold_count=0
        for field in after_consecutive_unavailable after_duration_seconds after_failed_remediations; do
            value_type="$(yaml_read ".services[$index].escalation.levels[$level].${field} | type")"
            [[ "$value_type" == '!!null' ]] && continue
            value="$(yaml_read ".services[$index].escalation.levels[$level].${field}")"
            is_positive_integer "$value" || die "services[$index].escalation.levels[$level].${field} must be positive."
            ((threshold_count++))
        done
        (( threshold_count > 0 )) || die "services[$index].escalation.levels[$level] needs a threshold."
        for field in notify manual_intervention; do
            value="$(yaml_read ".services[$index].escalation.levels[$level].${field} // false")"
            [[ "$value" == true || "$value" == false ]] || die "services[$index].escalation.levels[$level].${field} must be boolean."
        done
    done
    value="$(yaml_read ".services[$index].escalation.cooldown // 0")"
    is_non_negative_integer "$value" || die "Service '${service_name}': escalation.cooldown must be non-negative."
    value="$(yaml_read_true_default ".services[$index].escalation.notify")"
    [[ "$value" == true || "$value" == false ]] ||
        die "Service '${service_name}': escalation.notify must be true or false."
    value="$(yaml_read ".services[$index].escalation.manual_intervention // false")"
    [[ "$value" == true || "$value" == false ]] || die "services[$index].escalation.manual_intervention must be true or false."
    value_type="$(yaml_read ".services[$index].escalation.actions.commands | type")"
    if [[ "$value_type" != "!!null" ]]; then
        validate_command_sequence ".services[$index].escalation.actions.commands" \
            "Service '${service_name}': escalation.actions.commands" true
    fi
    hooks_type="$(yaml_read ".services[$index].escalation.hooks.on_escalation | type")"
    if [[ "$hooks_type" != "!!null" ]]; then
        validate_command_sequence ".services[$index].escalation.hooks.on_escalation" \
            "Service '${service_name}': escalation.hooks.on_escalation" true
    fi
}

validate_circuit_breaker_configuration() {
    local index="$1" service_name="$2" type enabled value value_type
    type="$(yaml_read ".services[$index].circuit_breaker | type")"
    [[ "$type" == "!!null" ]] && return 0
    [[ "$type" == "!!map" ]] || die "Service '${service_name}': circuit_breaker must be a YAML map."
    enabled="$(yaml_read ".services[$index].circuit_breaker.enabled")"
    [[ "$enabled" == true || "$enabled" == false ]] || die "Service '${service_name}': circuit_breaker.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    value="$(yaml_read ".services[$index].circuit_breaker.failure_threshold")"
    is_positive_integer "$value" || die "Service '${service_name}': circuit_breaker.failure_threshold must be a positive integer."
    value="$(yaml_read ".services[$index].circuit_breaker.open_duration")"
    is_positive_integer "$value" || die "Service '${service_name}': circuit_breaker.open_duration must be a positive integer."
    value="$(yaml_read ".services[$index].circuit_breaker.half_open_verify_after // 0")"
    is_non_negative_integer "$value" || die "Service '${service_name}': circuit_breaker.half_open_verify_after must be non-negative."
    value="$(yaml_read_true_default ".services[$index].circuit_breaker.notify")"
    [[ "$value" == true || "$value" == false ]] || die "Service '${service_name}': circuit_breaker.notify must be true or false."
    value_type="$(yaml_read ".services[$index].circuit_breaker.hooks.on_open | type")"
    [[ "$value_type" == "!!null" ]] || validate_command_sequence ".services[$index].circuit_breaker.hooks.on_open" "Service '${service_name}': circuit_breaker.hooks.on_open" true
    value_type="$(yaml_read ".services[$index].circuit_breaker.hooks.on_close | type")"
    [[ "$value_type" == "!!null" ]] || validate_command_sequence ".services[$index].circuit_breaker.hooks.on_close" "Service '${service_name}': circuit_breaker.hooks.on_close" true
}

validate_flapping_configuration() {
    local index="$1" value field type
    type="$(yaml_read ".services[$index].flapping | type")"
    [[ "$type" == '!!null' ]] && return 0
    [[ "$type" == '!!map' ]] || die "services[$index].flapping must be a map."
    value="$(yaml_read ".services[$index].flapping.enabled // false")"
    [[ "$value" == true || "$value" == false ]] || die "services[$index].flapping.enabled must be true or false."
    [[ "$value" == true ]] || return 0
    for field in window_seconds threshold hold_seconds recovery_seconds; do
        value="$(yaml_read ".services[$index].flapping.${field}")"
        if ! is_positive_integer "$value" || (( 10#$value > 86400 )); then
            die "services[$index].flapping.${field} must be from 1 to 86400."
        fi
    done
    value="$(yaml_read_true_default ".services[$index].flapping.notify")"
    [[ "$value" == true || "$value" == false ]] || die "services[$index].flapping.notify must be true or false."
}

validate_backoff_configuration() {
    local index="$1" value field type initial maximum
    type="$(yaml_read ".services[$index].actions.backoff | type")"
    [[ "$type" == '!!null' ]] && return 0
    [[ "$type" == '!!map' ]] || die "services[$index].actions.backoff must be a map."
    value="$(yaml_read ".services[$index].actions.backoff.enabled // false")"
    [[ "$value" == true || "$value" == false ]] || die "services[$index].actions.backoff.enabled must be true or false."
    [[ "$value" == true ]] || return 0
    for field in initial_delay multiplier max_delay; do
        value="$(yaml_read ".services[$index].actions.backoff.${field}")"
        if ! is_positive_integer "$value" || (( 10#$value > 86400 )); then
            die "services[$index].actions.backoff.${field} must be from 1 to 86400."
        fi
    done
    initial="$(yaml_read ".services[$index].actions.backoff.initial_delay")"
    maximum="$(yaml_read ".services[$index].actions.backoff.max_delay")"
    (( 10#$initial <= 10#$maximum )) || die "services[$index].actions.backoff.max_delay must be at least initial_delay."
}

validate_metrics_configuration() {
    local enabled value labels_type count index key value_type
    enabled="$(yaml_read '.metrics.enabled // false')"
    [[ "$enabled" == true || "$enabled" == false ]] || die "metrics.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    validate_string '.metrics.textfile_directory' 'metrics.textfile_directory'
    value="$(yaml_read '.metrics.textfile_directory')"
    [[ "$value" == /* ]] || die "metrics.textfile_directory must be an absolute path."
    validate_string '.metrics.filename' 'metrics.filename'
    value="$(yaml_read '.metrics.filename')"
    [[ -n "$value" && "$value" != */* ]] || die "metrics.filename must be a file name, not a path."
    validate_string '.metrics.prefix' 'metrics.prefix'
    value="$(yaml_read '.metrics.prefix')"
    [[ "$value" =~ ^[A-Za-z_:][A-Za-z0-9_:]*$ ]] || die "metrics.prefix is not a valid Prometheus metric prefix."
    labels_type="$(yaml_read '.metrics.static_labels | type')"
    [[ "$labels_type" == "!!null" ]] && return 0
    [[ "$labels_type" == "!!map" ]] || die "metrics.static_labels must be a YAML map."
    count="$(yaml_read '.metrics.static_labels | length')"
    for ((index = 0; index < count; index++)); do
        key="$(yaml_read ".metrics.static_labels | to_entries[$index].key")"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid Prometheus static label name: ${key}"
        [[ "$key" != service && "$key" != check_type ]] || die "metrics.static_labels.${key} is reserved."
        value_type="$(yaml_read ".metrics.static_labels | to_entries[$index].value | type")"
        [[ "$value_type" == "!!str" || "$value_type" == "!!int" || "$value_type" == "!!float" || "$value_type" == "!!bool" ]] ||
            die "metrics.static_labels.${key} must be scalar."
    done
}

validate_status_page_configuration() {
    local enabled value theme_key type refresh
    enabled="$(yaml_read '.status_page.enabled // false')"
    [[ "$enabled" == true || "$enabled" == false ]] || die "status_page.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    validate_string '.status_page.output_directory' 'status_page.output_directory'
    value="$(yaml_read '.status_page.output_directory')"
    [[ "$value" == /* ]] || die "status_page.output_directory must be an absolute path."
    for theme_key in html_filename json_filename title description logo_url footer; do
        type="$(yaml_read ".status_page.${theme_key} | type")"
        [[ "$type" == "!!null" ]] || validate_string ".status_page.${theme_key}" "status_page.${theme_key}"
    done
    for theme_key in html_filename json_filename; do
        value="$(yaml_read ".status_page.${theme_key} // \"\"")"
        [[ -z "$value" || "$value" != */* ]] || die "status_page.${theme_key} must be a file name, not a path."
    done
    for theme_key in primary danger warning bg card text muted; do
        value="$(yaml_read ".status_page.theme.${theme_key} // \"\"")"
        [[ -z "$value" || "$value" =~ ^[0-9A-Fa-f]{6}$ ]] || die "status_page.theme.${theme_key} must be a six-character hex color."
    done
    refresh="$(yaml_read '.status_page.auto_refresh // 0')"
    is_non_negative_integer "$refresh" || die "status_page.auto_refresh must be non-negative."
}

validate_parallel_configuration() {
    local value value_type
    value_type="$(yaml_read '.parallel | type')"
    [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "parallel must be a YAML map."
    value="$(yaml_read '.parallel.enabled // false')"
    [[ "$value" == true || "$value" == false ]] || die "parallel.enabled must be true or false."
    value="$(yaml_read '.parallel.max_jobs // 0')"
    is_non_negative_integer "$value" || die "parallel.max_jobs must be a non-negative integer."
    value="$(yaml_read '.parallel.timeout // 0')"
    is_non_negative_integer "$value" || die "parallel.timeout must be a non-negative integer."
    value_type="$(yaml_read '.parallel.temp_dir | type')"
    [[ "$value_type" == "!!null" || "$value_type" == "!!str" ]] || die "parallel.temp_dir must be a string."
    if [[ "$value_type" == "!!str" ]]; then
        value="$(yaml_read '.parallel.temp_dir')"
        [[ -z "$value" || "$value" == /* ]] || die "parallel.temp_dir must be an absolute path."
    fi
}

federation_validate_config() {
    local type enabled value value_type count index node_id
    local -A seen_nodes=()

    type="$(yaml_read '.federation | type')"
    [[ "$type" == "!!null" ]] && return 0
    [[ "$type" == "!!map" ]] || die "federation must be a YAML map."
    enabled="$(yaml_read '.federation.enabled // false')"
    [[ "$enabled" == true || "$enabled" == false ]] || die "federation.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0

    value_type="$(yaml_read '.federation.node_id | type')"
    [[ "$value_type" == "!!null" || "$value_type" == "!!str" ]] || die "federation.node_id must be a string."
    if [[ "$value_type" == "!!str" ]]; then
        node_id="$(yaml_read '.federation.node_id')"
        [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "federation.node_id contains unsupported characters."
    fi

    for type in agent hub; do
        value_type="$(yaml_read ".federation.${type} | type")"
        [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "federation.${type} must be a YAML map."
        value="$(yaml_read ".federation.${type}.enabled // false")"
        [[ "$value" == true || "$value" == false ]] || die "federation.${type}.enabled must be true or false."
    done

    enabled="$(yaml_read '.federation.agent.enabled // false')"
    if [[ "$enabled" == true ]]; then
        value="$(yaml_read '.federation.agent.transport // "http"')"
        [[ "$value" == http || "$value" == file ]] || die "federation.agent.transport must be http or file."
        value="$(yaml_read '.federation.agent.timeout // 10')"
        is_positive_integer "$value" || die "federation.agent.timeout must be a positive integer."
        value="$(yaml_read_true_default '.federation.agent.heartbeat')"
        [[ "$value" == true || "$value" == false ]] || die "federation.agent.heartbeat must be true or false."
        if [[ "$(yaml_read '.federation.agent.transport // "http"')" == http ]]; then
            validate_string '.federation.agent.hub_url' 'federation.agent.hub_url'
            value="$(yaml_read '.federation.agent.hub_url')"
            [[ "$value" =~ ^https?://[^[:space:]]+$ ]] || die "federation.agent.hub_url must be an HTTP(S) URL without spaces."
            validate_string '.federation.agent.token_env' 'federation.agent.token_env'
            value="$(yaml_read '.federation.agent.token_env')"
            [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "federation.agent.token_env is not a valid environment variable name."
        else
            validate_string '.federation.agent.report_path' 'federation.agent.report_path'
            value="$(yaml_read '.federation.agent.report_path')"
            [[ "$value" == /* ]] || die "federation.agent.report_path must be an absolute path."
        fi
    fi

    enabled="$(yaml_read '.federation.hub.enabled // false')"
    if [[ "$enabled" == true ]]; then
        for value in incoming_dir archive_dir; do
            validate_string ".federation.hub.${value}" "federation.hub.${value}"
            node_id="$(yaml_read ".federation.hub.${value}")"
            [[ "$node_id" == /* ]] || die "federation.hub.${value} must be an absolute path."
        done
        value="$(yaml_read '.federation.hub.max_report_age // 300')"
        is_positive_integer "$value" || die "federation.hub.max_report_age must be a positive integer."
        value="$(yaml_read '.federation.hub.archive_retention_days // 0')"
        is_non_negative_integer "$value" || die "federation.hub.archive_retention_days must be a non-negative integer."
        value_type="$(yaml_read '.federation.hub.expected_nodes | type')"
        [[ "$value_type" == "!!null" || "$value_type" == "!!seq" ]] || die "federation.hub.expected_nodes must be a YAML array."
        if [[ "$value_type" == "!!seq" ]]; then
            count="$(yaml_read '.federation.hub.expected_nodes | length')"
            for ((index = 0; index < count; index++)); do
                validate_string ".federation.hub.expected_nodes[$index]" "federation.hub.expected_nodes[$index]"
                node_id="$(yaml_read ".federation.hub.expected_nodes[$index]")"
                [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid federation expected node: ${node_id}"
                [[ -z "${seen_nodes[$node_id]:-}" ]] || die "Duplicate federation expected node: ${node_id}"
                seen_nodes["$node_id"]=1
            done
        fi
        for value in overall_change agent_offline any_service_change; do
            node_id="$(yaml_read_true_default ".federation.hub.notify_on.${value}")"
            [[ "$node_id" == true || "$node_id" == false ]] || die "federation.hub.notify_on.${value} must be true or false."
        done
        value_type="$(yaml_read '.federation.hub.templates | type')"
        [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "federation.hub.templates must be a YAML map."
        for type in overall_failure overall_recovery agent_offline; do
            value_type="$(yaml_read ".federation.hub.templates.${type} | type")"
            [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "federation.hub.templates.${type} must be a YAML map."
            for value in subject body; do
                value_type="$(yaml_read ".federation.hub.templates.${type}.${value} | type")"
                [[ "$value_type" == "!!null" || "$value_type" == "!!str" ]] || die "federation.hub.templates.${type}.${value} must be a string."
            done
        done
    fi

    [[ "$(yaml_read '.federation.agent.enabled // false')" == true && "$(yaml_read '.federation.hub.enabled // false')" == true ]] &&
        die "federation.agent and federation.hub must use separate watchdog instances."
}

build_dependency_graph() {
    local service_count index service_name dependencies_type dependency_count dependency dependency_name required
    local candidate candidate_dependencies candidate_dependency progress blocked

    SERVICE_INDEX=(); DEPENDENCY_NAMES=(); DEPENDENCY_REQUIRED=(); SERVICE_LEVEL=(); SERVICE_ORDER=()
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        SERVICE_INDEX["$service_name"]="$index"
        DEPENDENCY_NAMES["$service_name"]=""
    done
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        dependencies_type="$(yaml_read ".services[$index].depends_on | type")"
        [[ "$dependencies_type" == "!!null" ]] && continue
        [[ "$dependencies_type" == "!!seq" ]] || die "Service '${service_name}': depends_on must be a YAML array."
        dependency_count="$(yaml_read ".services[$index].depends_on | length")"
        for ((dependency = 0; dependency < dependency_count; dependency++)); do
            validate_string ".services[$index].depends_on[$dependency].name" \
                "Service '${service_name}': depends_on[$dependency].name"
            dependency_name="$(yaml_read ".services[$index].depends_on[$dependency].name")"
            [[ "$dependency_name" != "$service_name" ]] ||
                die "result=config-error reason=self_dependency service=${service_name}"
            [[ -n "${SERVICE_INDEX[$dependency_name]:-}" ]] ||
                die "result=config-error reason=missing_dependency service=${service_name} dependency=${dependency_name}"
            required="$(yaml_read_true_default ".services[$index].depends_on[$dependency].required")"
            [[ "$required" == true || "$required" == false ]] ||
                die "Service '${service_name}': depends_on[$dependency].required must be true or false."
            DEPENDENCY_NAMES["$service_name"]+=$'\t'"${dependency_name}"
            DEPENDENCY_REQUIRED["${service_name}:${dependency_name}"]="$required"
        done
    done

    local -A completed=()
    local candidate_level dependency_level
    while (( ${#SERVICE_ORDER[@]} < service_count )); do
        progress=0
        for ((index = 0; index < service_count; index++)); do
            candidate="$(yaml_read ".services[$index].name")"
            [[ -z "${completed[$candidate]:-}" ]] || continue
            candidate_dependencies="${DEPENDENCY_NAMES[$candidate]:-}"
            blocked=0
            for candidate_dependency in $candidate_dependencies; do
                [[ -n "${completed[$candidate_dependency]:-}" ]] || { blocked=1; break; }
            done
            (( blocked == 0 )) || continue
            candidate_level=0
            for candidate_dependency in $candidate_dependencies; do
                dependency_level="${SERVICE_LEVEL[$candidate_dependency]:-0}"
                (( candidate_level < dependency_level + 1 )) && candidate_level=$((dependency_level + 1))
            done
            completed["$candidate"]=1
            SERVICE_LEVEL["$candidate"]="$candidate_level"
            SERVICE_ORDER+=("$candidate")
            progress=1
        done
        (( progress == 1 )) || die "result=config-error reason=circular_dependency cycle=dependency-graph"
    done
}

validate_threshold_source() {
    local expression="$1" description="$2" source_type value value_type index count item_type pattern_status
    [[ "$(yaml_read "${expression} | type")" == '!!map' ]] || die "${description} must be a map."
    validate_string "${expression}.type" "${description}.type"
    source_type="$(yaml_read "${expression}.type")"
    case "$source_type" in
        journald)
            for value in unit since pattern; do
                validate_string "${expression}.${value}" "${description}.${value}"
                [[ -n "$(yaml_read "${expression}.${value}")" ]] || die "${description}.${value} must not be empty."
            done
            command -v journalctl >/dev/null 2>&1 || die "${description}.type=journald requires journalctl in PATH."
            ;;
        logfile)
            validate_string "${expression}.path" "${description}.path"
            value="$(yaml_read "${expression}.path")"
            [[ "$value" == /* ]] || die "${description}.path must be absolute."
            [[ -f "$value" && -r "$value" ]] || die "${description}.path must be a readable file."
            validate_string "${expression}.pattern" "${description}.pattern"
            value="$(yaml_read "${expression}.tail_lines // 10000")"
            is_positive_integer "$value" || die "${description}.tail_lines must be a positive integer."
            (( 10#$value <= 1000000 )) || die "${description}.tail_lines must not exceed 1000000."
            ;;
        netstat)
            value_type="$(yaml_read "${expression}.state | type")"
            if [[ "$value_type" == '!!null' ]]; then
                validate_string "${expression}.pattern" "${description}.pattern"
                [[ -n "$(yaml_read "${expression}.pattern")" ]] || die "${description}.pattern must not be empty."
            else
                validate_string "${expression}.state" "${description}.state"
                value="$(yaml_read "${expression}.state")"
                [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "${description}.state has an invalid socket state."
                [[ "$(yaml_read "${expression}.pattern | type")" == '!!null' ]] || die "${description} must set either state or pattern, not both."
            fi
            { command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; } || die "${description}.type=netstat requires ss or netstat in PATH."
            ;;
        command)
            [[ "$(yaml_read "${expression}.command | type")" == '!!seq' ]] || die "${description}.command must be an argv array."
            count="$(yaml_read "${expression}.command | length")"
            (( count > 0 )) || die "${description}.command must not be empty."
            for ((index = 0; index < count; index++)); do
                item_type="$(yaml_read "${expression}.command[$index] | type")"
                case "$item_type" in '!!str'|'!!int'|'!!float'|'!!bool') ;; *) die "${description}.command[$index] must be scalar." ;; esac
            done
            value="$(yaml_read "${expression}.timeout // ${DEFAULT_TIMEOUT}")"
            is_positive_integer "$value" || die "${description}.timeout must be a positive integer."
            ;;
        *) die "${description}.type must be journald, logfile, netstat, or command." ;;
    esac
    value_type="$(yaml_read "${expression}.pattern | type")"
    if [[ "$value_type" != '!!null' ]]; then
        validate_string "${expression}.pattern" "${description}.pattern"
        value="$(yaml_read "${expression}.pattern")"
        [[ -n "$value" ]] || die "${description}.pattern must not be empty."
        printf '' | grep -E -- "$value" >/dev/null 2>&1
        pattern_status=$?
        (( pattern_status <= 1 )) || die "${description}.pattern is not a valid extended regular expression."
    fi
}

validate_check_definition() {
    local expression="$1" description="$2" check_type value value_type status_count status_index status_code port field threshold_count=0
    local header_count header_index header_type header_name header_value_type header_env_type pattern_status
    validate_string "${expression}.type" "${description}.type"
    check_type="$(yaml_read "${expression}.type")"
    case "$check_type" in
        http)
            validate_string "${expression}.url" "${description}.url"
            value="$(yaml_read "${expression}.url")"
            [[ "$value" =~ ^https?://[^[:space:]]+$ ]] || die "${description}.url must be an HTTP(S) URL without spaces."
            value="$(yaml_read "${expression}.method // \"GET\"")"
            [[ "$value" == GET || "$value" == HEAD ]] || die "${description}.method must be GET or HEAD."
            value="$(yaml_read_true_default "${expression}.follow_redirects")"
            [[ "$value" == true || "$value" == false ]] || die "${description}.follow_redirects must be true or false."
            value_type="$(yaml_read "${expression}.success_status | type")"
            if [[ "$value_type" != '!!null' ]]; then
                [[ "$value_type" == '!!seq' ]] || die "${description}.success_status must be an array."
                status_count="$(yaml_read "${expression}.success_status | length")"
                (( status_count > 0 )) || die "${description}.success_status must not be empty."
                for ((status_index = 0; status_index < status_count; status_index++)); do
                    status_code="$(yaml_read "${expression}.success_status[$status_index]")"
                    if ! [[ "$status_code" =~ ^[0-9]{3}$ ]] || (( 10#$status_code < 100 || 10#$status_code > 599 )); then
                        die "${description}.success_status[$status_index] must be an HTTP status from 100 to 599."
                    fi
                done
            fi
            value_type="$(yaml_read "${expression}.headers | type")"
            if [[ "$value_type" != '!!null' ]]; then
                [[ "$value_type" == '!!seq' ]] || die "${description}.headers must be an array."
                header_count="$(yaml_read "${expression}.headers | length")"
                for ((header_index = 0; header_index < header_count; header_index++)); do
                    header_type="$(yaml_read "${expression}.headers[$header_index] | type")"
                    [[ "$header_type" == '!!map' ]] || die "${description}.headers[$header_index] must be a map."
                    validate_string "${expression}.headers[$header_index].name" "${description}.headers[$header_index].name"
                    header_name="$(yaml_read "${expression}.headers[$header_index].name")"
                    [[ -n "$header_name" && "$header_name" != *[$' \t\r\n:']* ]] || die "${description}.headers[$header_index].name must be a non-empty HTTP header name."
                    header_value_type="$(yaml_read "${expression}.headers[$header_index].value | type")"
                    header_env_type="$(yaml_read "${expression}.headers[$header_index].value_env | type")"
                    [[ "$header_value_type" == '!!null' || "$header_value_type" == '!!str' ]] || die "${description}.headers[$header_index].value must be a string."
                    [[ "$header_env_type" == '!!null' || "$header_env_type" == '!!str' ]] || die "${description}.headers[$header_index].value_env must be a string."
                    [[ "$header_value_type" == '!!null' || "$header_env_type" == '!!null' ]] || die "${description}.headers[$header_index] must set only one of value or value_env."
                    [[ "$header_value_type" != '!!null' || "$header_env_type" != '!!null' ]] || die "${description}.headers[$header_index] needs value or value_env."
                    if [[ "$header_value_type" != '!!null' ]]; then
                        value="$(yaml_read "${expression}.headers[$header_index].value")"
                        [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || die "${description}.headers[$header_index].value must not contain a newline."
                    else
                        validate_string "${expression}.headers[$header_index].value_env" "${description}.headers[$header_index].value_env"
                        value="$(yaml_read "${expression}.headers[$header_index].value_env")"
                        [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "${description}.headers[$header_index].value_env is not a valid environment variable name."
                    fi
                done
            fi
            value_type="$(yaml_read "${expression}.expect | type")"
            if [[ "$value_type" != '!!null' ]]; then
                [[ "$value_type" == '!!map' ]] || die "${description}.expect must be a map."
                value_type="$(yaml_read "${expression}.expect.content_type | type")"
                if [[ "$value_type" != '!!null' ]]; then
                    validate_string "${expression}.expect.content_type" "${description}.expect.content_type"
                    value="$(yaml_read "${expression}.expect.content_type")"
                    [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] || die "${description}.expect.content_type must not be empty or contain a newline."
                fi
                value_type="$(yaml_read "${expression}.expect.body_regex | type")"
                if [[ "$value_type" != '!!null' ]]; then
                    validate_string "${expression}.expect.body_regex" "${description}.expect.body_regex"
                    value="$(yaml_read "${expression}.expect.body_regex")"
                    [[ -n "$value" ]] || die "${description}.expect.body_regex must not be empty."
                    printf '' | grep -E -- "$value" >/dev/null 2>&1
                    pattern_status=$?
                    (( pattern_status <= 1 )) || die "${description}.expect.body_regex is not a valid extended regular expression."
                fi
                value_type="$(yaml_read "${expression}.expect.max_total_ms | type")"
                if [[ "$value_type" != '!!null' ]]; then
                    [[ "$value_type" == '!!int' || "$value_type" == '!!str' ]] || die "${description}.expect.max_total_ms must be a positive integer."
                    value="$(yaml_read "${expression}.expect.max_total_ms")"
                    is_positive_integer "$value" || die "${description}.expect.max_total_ms must be a positive integer."
                fi
            fi
            ;;
        tcp)
            validate_string "${expression}.host" "${description}.host"
            value="$(yaml_read "${expression}.host")"
            [[ -n "$value" && "$value" != *[[:space:]]* ]] || die "${description}.host must not be empty or contain spaces."
            port="$(yaml_read "${expression}.port")"
            if ! is_positive_integer "$port" || (( 10#$port > 65535 )); then
                die "${description}.port must be from 1 through 65535."
            fi
            ;;
        command)
            validate_command_sequence "${expression}.commands" "${description}.commands"
            ;;
        disk)
            validate_string "${expression}.path" "${description}.path"
            value="$(yaml_read "${expression}.path")"
            [[ "$value" == /* ]] || die "${description}.path must be absolute."
            for field in min_free_gb min_free_percent; do
                value_type="$(yaml_read "${expression}.${field} | type")"
                [[ "$value_type" == '!!null' ]] && continue
                [[ "$value_type" == '!!int' || "$value_type" == '!!float' ]] ||
                    die "${description}.${field} must be a number."
                value="$(yaml_read "${expression}.${field}")"
                is_non_negative_number "$value" || die "${description}.${field} must be non-negative."
                if [[ "$field" == min_free_percent ]] &&
                    ! LC_ALL=C awk -v threshold="$value" 'BEGIN { exit !(threshold <= 100) }'; then
                    die "${description}.min_free_percent must not exceed 100."
                fi
                threshold_count=$((threshold_count + 1))
            done
            (( threshold_count > 0 )) ||
                die "${description} needs min_free_gb or min_free_percent."
            ;;
        tls_cert)
            validate_string "${expression}.host" "${description}.host"
            value="$(yaml_read "${expression}.host")"
            [[ -n "$value" && "$value" != *[[:space:]]* ]] || die "${description}.host must not be empty or contain spaces."
            port="$(yaml_read "${expression}.port // 443")"
            if ! is_positive_integer "$port" || (( 10#$port > 65535 )); then
                die "${description}.port must be from 1 through 65535."
            fi
            value_type="$(yaml_read "${expression}.server_name | type")"
            if [[ "$value_type" != '!!null' ]]; then
                validate_string "${expression}.server_name" "${description}.server_name"
                value="$(yaml_read "${expression}.server_name")"
                [[ -n "$value" && "$value" != *[[:space:]]* ]] || die "${description}.server_name must not be empty or contain spaces."
            fi
            value_type="$(yaml_read "${expression}.min_days_remaining | type")"
            [[ "$value_type" == '!!int' ]] || die "${description}.min_days_remaining must be a non-negative integer."
            value="$(yaml_read "${expression}.min_days_remaining")"
            is_non_negative_integer "$value" || die "${description}.min_days_remaining must be a non-negative integer."
            (( 10#$value <= 36500 )) || die "${description}.min_days_remaining must not exceed 36500."
            command -v openssl >/dev/null 2>&1 || die "${description}.type=tls_cert requires openssl in PATH."
            ;;
        clamav)
            validate_string "${expression}.path" "${description}.path"
            value="$(yaml_read "${expression}.path")"
            [[ "$value" == /* ]] || die "${description}.path must be absolute."
            [[ -e "$value" && -r "$value" ]] || die "${description}.path must exist and be readable."
            value="$(yaml_read "${expression}.recursive // false")"
            [[ "$value" == true || "$value" == false ]] || die "${description}.recursive must be true or false."
            command -v clamscan >/dev/null 2>&1 || die "${description}.type=clamav requires clamscan in PATH."
            ;;
        threshold)
            value_type="$(yaml_read "${expression}.threshold | type")"
            [[ "$value_type" == '!!int' || "$value_type" == '!!float' ]] || die "${description}.threshold must be a number."
            value="$(yaml_read "${expression}.threshold")"
            is_non_negative_number "$value" || die "${description}.threshold must be non-negative."
            value="$(yaml_read "${expression}.comparator // \">\"")"
            case "$value" in '>'|'>='|'<'|'<='|'=='|'!=') ;; *) die "${description}.comparator must be >, >=, <, <=, ==, or !=." ;; esac
            validate_threshold_source "${expression}.source" "${description}.source"
            ;;
        *) die "${description}.type must be http, tcp, command, disk, tls_cert, clamav, or threshold." ;;
    esac
    for field in timeout attempts retry_delay; do
        case "$field" in
            timeout)
                if [[ "$check_type" == clamav ]]; then value="$(yaml_read "${expression}.timeout // 300")"; else value="$(yaml_read "${expression}.timeout // ${DEFAULT_TIMEOUT}")"; fi
                ;;
            attempts) value="$(yaml_read "${expression}.attempts // ${DEFAULT_ATTEMPTS}")" ;;
            retry_delay) value="$(yaml_read "${expression}.retry_delay // ${DEFAULT_RETRY_DELAY}")" ;;
        esac
        if [[ "$field" == retry_delay ]]; then
            is_non_negative_integer "$value" || die "${description}.${field} must be a non-negative integer."
        else
            is_positive_integer "$value" || die "${description}.${field} must be a positive integer."
        fi
    done
}

validate_configuration() {
    local services_type service_count index name enabled value value_type
    local actions_type hooks_type hook_name health_type check_type
    local -A seen_names=()

    yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1 ||
        die "YAML is syntactically invalid: ${CONFIG_FILE}"

    validate_parallel_configuration
    federation_validate_config

    services_type="$(yaml_read '.services | type')"
    [[ "$services_type" == "!!seq" ]] || die ".services must be a YAML array."
    service_count="$(yaml_read '.services | length')"
    if (( service_count == 0 )) && [[ "$(yaml_read '.federation.hub.enabled // false')" != true ]]; then
        die ".services must contain at least one service."
    fi

    for ((index = 0; index < service_count; index++)); do
        validate_string ".services[$index].name" ".services[$index].name"
        name="$(yaml_read ".services[$index].name")"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
            die "Service name may contain only letters, digits, dots, underscores, and hyphens: ${name}"
        [[ -z "${seen_names[$name]:-}" ]] || die "Duplicate service name: ${name}"
        seen_names["$name"]=1

        enabled="$(yaml_read_true_default ".services[$index].enabled")"
        [[ "$enabled" == "true" || "$enabled" == "false" ]] ||
            die "Service '${name}': enabled must be true or false."

        value_type="$(yaml_read ".services[$index].parallel | type")"
        [[ "$value_type" == "!!null" || "$value_type" == "!!bool" ]] ||
            die "Service '${name}': parallel must be true or false."

        health_type="$(yaml_read ".services[$index].health | type")"
        check_type="$(yaml_read ".services[$index].check | type")"
        if [[ "$health_type" == '!!null' ]]; then
            validate_check_definition ".services[$index].check" "services[$index].check"
        else
            [[ "$health_type" == '!!map' && "$check_type" == '!!null' ]] ||
                die "services[$index]: configure either check or health.liveness/readiness."
            validate_check_definition ".services[$index].health.liveness" "services[$index].health.liveness"
            validate_check_definition ".services[$index].health.readiness" "services[$index].health.readiness"
            [[ "$(yaml_read ".services[$index].health.liveness.type")" == http &&
               "$(yaml_read ".services[$index].health.readiness.type")" == http ]] ||
                die "services[$index].health liveness and readiness must use HTTP checks."
        fi

        actions_type="$(yaml_read ".services[$index].actions.commands | type")"
        if [[ "$actions_type" != "!!null" ]]; then
            validate_command_sequence ".services[$index].actions.commands" \
                "Service '${name}': actions.commands" true
        fi
        value="$(yaml_read ".services[$index].actions.cooldown // ${DEFAULT_ACTION_COOLDOWN}")"
        is_non_negative_integer "$value" ||
            die "Service '${name}': actions.cooldown must be a non-negative integer."
        value="$(yaml_read ".services[$index].actions.verify_after // 0")"
        is_non_negative_integer "$value" ||
            die "Service '${name}': actions.verify_after must be a non-negative integer."
        validate_only_if_configuration "$index" "$name"
        validate_flapping_configuration "$index"
        validate_backoff_configuration "$index"
        validate_maintenance_configuration "$index" "$name"
        validate_escalation_configuration "$index" "$name"
        validate_circuit_breaker_configuration "$index" "$name"
    done

    hooks_type="$(yaml_read '.hooks | type')"
    if [[ "$hooks_type" != "!!null" ]]; then
        [[ "$hooks_type" == "!!map" ]] || die ".hooks must be a YAML map."
        for hook_name in on_failure on_recovery; do
            value_type="$(yaml_read ".hooks.${hook_name} | type")"
            if [[ "$value_type" != "!!null" ]]; then
                validate_command_sequence ".hooks.${hook_name}" ".hooks.${hook_name}" true
            fi
        done
    fi

    validate_email_configuration
    validate_webhook_configuration
    validate_metrics_configuration
    validate_status_page_configuration
    build_dependency_graph
    validate_security_policy
}

load_runtime_settings() {
    local value

    value="$(yaml_read '.settings.default_timeout // 10')"
    is_positive_integer "$value" || die "settings.default_timeout must be positive."
    DEFAULT_TIMEOUT="$((10#$value))"
    value="$(yaml_read '.settings.default_attempts // 2')"
    is_positive_integer "$value" || die "settings.default_attempts must be positive."
    (( 10#$value <= 10 )) || die "settings.default_attempts must not exceed 10."
    DEFAULT_ATTEMPTS="$((10#$value))"
    value="$(yaml_read '.settings.default_retry_delay // 2')"
    is_non_negative_integer "$value" || die "settings.default_retry_delay must be non-negative."
    DEFAULT_RETRY_DELAY="$((10#$value))"
    value="$(yaml_read '.settings.default_action_timeout // 120')"
    is_positive_integer "$value" || die "settings.default_action_timeout must be positive."
    DEFAULT_ACTION_TIMEOUT="$((10#$value))"
    value="$(yaml_read '.settings.default_action_cooldown // 300')"
    is_non_negative_integer "$value" || die "settings.default_action_cooldown must be non-negative."
    DEFAULT_ACTION_COOLDOWN="$((10#$value))"

    LOG_FILE="$(yaml_read '.settings.log_file')"
    LOCK_FILE="$(yaml_read '.settings.lock_file')"
    STATE_DIRECTORY="$(yaml_read '.settings.state_directory')"
    for value in "$LOG_FILE" "$LOCK_FILE" "$STATE_DIRECTORY"; do
        [[ -n "$value" && "$value" == /* ]] ||
            die "settings.log_file, lock_file, and state_directory must be absolute paths."
    done
}

configure_runtime() {
    local directory
    for directory in "$(dirname -- "$LOG_FILE")" "$(dirname -- "$LOCK_FILE")"; do
        mkdir -p -- "$directory" || die "Cannot create directory: ${directory}"
    done
    touch -- "$LOG_FILE" || die "Cannot write log file: ${LOG_FILE}"
    chmod 0640 "$LOG_FILE" 2>/dev/null || true
    if (( DRY_RUN == 0 )); then
        mkdir -p -- "$STATE_DIRECTORY" || die "Cannot create directory: ${STATE_DIRECTORY}"
        chmod 0750 "$STATE_DIRECTORY" 2>/dev/null || true
    fi
}

configure_parallel() {
    local value configured_directory
    [[ "$(yaml_read '.parallel.enabled // false')" == true ]] && PARALLEL_ENABLED=1
    value="$(yaml_read '.parallel.max_jobs // 0')"
    PARALLEL_MAX_JOBS="$((10#$value))"
    value="$(yaml_read '.parallel.timeout // 0')"
    PARALLEL_TIMEOUT="$((10#$value))"
    configured_directory="$(yaml_read '.parallel.temp_dir // ""')"
    if [[ -n "$configured_directory" ]] && mkdir -p -- "$configured_directory" 2>/dev/null && [[ -w "$configured_directory" ]]; then
        PARALLEL_TEMP_BASE="$configured_directory"
    else
        [[ -z "$configured_directory" ]] || log WARN "phase=check mode=parallel temp_dir=${configured_directory} result=fallback-to-tmp"
        PARALLEL_TEMP_BASE="/tmp"
    fi
}

configure_email() {
    local enabled password_env password

    enabled="$(yaml_read '.notifications.email.enabled // false')"
    [[ "$enabled" == true ]] || return 0
    EMAIL_ENABLED=1
    EMAIL_SMTP_URL="$(yaml_read '.notifications.email.smtp.url')"
    EMAIL_FROM="$(yaml_read '.notifications.email.smtp.from')"
    EMAIL_USERNAME="$(yaml_read '.notifications.email.smtp.username // ""')"
    EMAIL_TLS_REQUIRED=0
    EMAIL_INSECURE_SKIP_VERIFY=0
    [[ "$(yaml_read_true_default '.notifications.email.smtp.tls_required')" == true ]] &&
        EMAIL_TLS_REQUIRED=1
    [[ "$(yaml_read '.notifications.email.smtp.insecure_skip_verify // false')" == true ]] &&
        EMAIL_INSECURE_SKIP_VERIFY=1
    EMAIL_TIMEOUT="$(yaml_read '.notifications.email.smtp.timeout // 30')"
    EMAIL_RECIPIENTS_COUNT="$(yaml_read '.notifications.email.recipients | length')"
    EMAIL_FAILURE_SUBJECT="$(yaml_read '.notifications.email.failure.subject')"
    EMAIL_FAILURE_BODY="$(yaml_read '.notifications.email.failure.body')"
    EMAIL_RECOVERY_SUBJECT="$(yaml_read '.notifications.email.recovery.subject')"
    EMAIL_RECOVERY_BODY="$(yaml_read '.notifications.email.recovery.body')"

    password_env="$(yaml_read '.notifications.email.smtp.password_env // ""')"
    password="$(yaml_read '.notifications.email.smtp.password // ""')"
    if [[ -n "$password_env" ]]; then
        EMAIL_PASSWORD="${!password_env:-}"
        if [[ -z "$EMAIL_PASSWORD" && "$DRY_RUN" != 1 ]]; then
            if (( NOTIFY_TEST_MODE == 1 )); then
                NOTIFY_TEST_DETAIL="missing environment variable ${password_env}"
                log ERROR "service=${CURRENT_SERVICE} result=test-email-failed reason=missing-env:${password_env}"
                return 1
            fi
            die "SMTP password environment variable is empty or undefined: ${password_env}"
        fi
    else
        EMAIL_PASSWORD="$password"
    fi

    [[ -z "$EMAIL_USERNAME" || -n "$EMAIL_PASSWORD" || "$DRY_RUN" == 1 ]] ||
        die "SMTP username is configured, but no password is available."
    [[ -n "$EMAIL_USERNAME" || -z "$EMAIL_PASSWORD" ]] ||
        die "SMTP password is configured, but smtp.username is empty."
    [[ "$EMAIL_PASSWORD" != *$'\r'* && "$EMAIL_PASSWORD" != *$'\n'* ]] ||
        die 'notifications.email.smtp.password must not contain a carriage return or newline.'
}

configure_metrics() {
    [[ "$(yaml_read '.metrics.enabled // false')" == true ]] || return 0
    METRICS_ENABLED=1
    METRICS_DIRECTORY="$(yaml_read '.metrics.textfile_directory')"
    METRICS_FILENAME="$(yaml_read '.metrics.filename')"
    METRICS_PREFIX="$(yaml_read '.metrics.prefix')"
    [[ "$METRICS_FILENAME" == *.prom ]] ||
        log WARN "result=metrics-warning reason=filename-not-prom filename=${METRICS_FILENAME}"
}

configure_status_page() {
    [[ "$(yaml_read '.status_page.enabled // false')" == true ]] || return 0
    STATUS_PAGE_ENABLED=1
    STATUS_PAGE_DIRECTORY="$(yaml_read '.status_page.output_directory')"
    STATUS_PAGE_HTML_FILENAME="$(yaml_read '.status_page.html_filename // "index.html"')"
    STATUS_PAGE_JSON_FILENAME="$(yaml_read '.status_page.json_filename // ""')"
}

configure_federation() {
    local value

    [[ "$(yaml_read '.federation.enabled // false')" == true ]] || return 0
    FEDERATION_NODE_ID="$(yaml_read '.federation.node_id // ""')"
    [[ -n "$FEDERATION_NODE_ID" ]] || FEDERATION_NODE_ID="$(hostname -s)"

    if [[ "$(yaml_read '.federation.agent.enabled // false')" == true ]]; then
        FEDERATION_AGENT_ENABLED=1
        FEDERATION_AGENT_TRANSPORT="$(yaml_read '.federation.agent.transport // "http"')"
        FEDERATION_AGENT_HUB_URL="$(yaml_read '.federation.agent.hub_url // ""')"
        FEDERATION_AGENT_TOKEN_ENV="$(yaml_read '.federation.agent.token_env // ""')"
        value="$(yaml_read '.federation.agent.timeout // 10')"
        FEDERATION_AGENT_TIMEOUT="$((10#$value))"
        FEDERATION_AGENT_REPORT_PATH="$(yaml_read '.federation.agent.report_path // ""')"
        if [[ "$(yaml_read_true_default '.federation.agent.heartbeat')" == true ]]; then
            FEDERATION_AGENT_HEARTBEAT=1
        else
            FEDERATION_AGENT_HEARTBEAT=0
        fi
    fi

    if [[ "$(yaml_read '.federation.hub.enabled // false')" == true ]]; then
        FEDERATION_HUB_ENABLED=1
        FEDERATION_HUB_INCOMING_DIRECTORY="$(yaml_read '.federation.hub.incoming_dir')"
        FEDERATION_HUB_ARCHIVE_DIRECTORY="$(yaml_read '.federation.hub.archive_dir')"
        value="$(yaml_read '.federation.hub.max_report_age // 300')"
        FEDERATION_HUB_MAX_REPORT_AGE="$((10#$value))"
        value="$(yaml_read '.federation.hub.archive_retention_days // 0')"
        FEDERATION_HUB_ARCHIVE_RETENTION_DAYS="$((10#$value))"
        FEDERATION_HUB_STATE_FILE="${STATE_DIRECTORY}/federation-hub-state.json"
    fi
}

load_command() {
    local expression="$1"
    local -n result_ref="$2"
    local length index argument
    length="$(yaml_read "${expression} | length")"
    result_ref=()
    for ((index = 0; index < length; index++)); do
        argument="$(yaml_read "${expression}[$index]")"
        result_ref+=("$argument")
    done
}

format_command() {
    local -n command_ref="$1"
    local result="" argument quoted
    for argument in "${command_ref[@]}"; do
        printf -v quoted '%q' "$argument"
        [[ -z "$result" ]] || result+=" "
        result+="$quoted"
    done
    printf '%s' "$result"
}

log_configured_sequence_plan() {
    local expression="$1" label="$2" service_name="$3" count command_index formatted
    local -a planned_command=()
    count="$(yaml_read "${expression} // [] | length")"
    for ((command_index = 0; command_index < count; command_index++)); do
        load_command "${expression}[$command_index].command" planned_command
        (( ${#planned_command[@]} > 0 )) || continue
        formatted="$(format_command planned_command)"
        log INFO "service=${service_name} action=${label}-command index=${command_index} result=would-run command=${formatted}"
    done
}

