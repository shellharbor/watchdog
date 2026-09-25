#!/usr/bin/env bash
# Offline configuration generator for Docker Compose and systemd services.
# Requires Bash >= 4.3 and Mike Farah yq v4; Docker/systemd are optional.

set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${WATCHDOG_CONFIG:-${SCRIPT_DIR}/config.yaml}"
SOURCE_FILTER=all
OUTPUT_FORMAT=auto
DRY_RUN=0
FORCE=0
OUTPUT_DIR=""
OUTPUT_PREFIX=auto-
OUTPUT_FILE=""
DISCOVERY_TEMP=""
SERVICES_TOTAL=0
UNIQUE_NAME=""
DOCKER_ENABLED=0
SYSTEMD_ENABLED=0
ONLY_WITH_HEALTHCHECK=0
DETECT_PORTS=1
declare -A DISCOVERED_NAMES=()
declare -A PROCESSED_COMPOSE=()
declare -A PROCESSED_UNITS=()

usage() {
    cat <<'EOF'
Usage: watchdog-discover.sh [--config FILE] [--source docker|systemd]
                            [--dry-run] [--format stdout] [--force]

Generate a reviewed YAML services fragment. Discovery never runs checks,
remediation, or notifications, and never changes watchdog state.
EOF
}

log_discovery() { printf '%s\n' "$*" >&2; }
die() { log_discovery "discovery=error reason=$1"; exit 2; }
cleanup() { [[ -z "$DISCOVERY_TEMP" || ! -e "$DISCOVERY_TEMP" ]] || rm -f -- "$DISCOVERY_TEMP"; }
trap cleanup EXIT

read_config() { yq eval -r "$1" "$CONFIG_FILE"; }
is_positive_integer() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
is_non_negative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

yaml_quote() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die 'multiline_value_not_supported'
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

sanitize_name() {
    local value="$1"
    value="$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^[^A-Za-z0-9]+//; s/-+$//')"
    [[ -n "$value" ]] || value=service
    printf '%s' "$value"
}

unique_name() {
    local base candidate suffix=2
    base="$(sanitize_name "$1")"
    candidate="$base"
    while [[ -n "${DISCOVERED_NAMES[$candidate]:-}" ]]; do
        candidate="${base}-${suffix}"
        suffix=$((suffix + 1))
    done
    DISCOVERED_NAMES["$candidate"]=1
    UNIQUE_NAME="$candidate"
}

expand_action_value() {
    local value="$1" service_name="$2" compose_dir="$3" unit_name="$4"
    value="${value//'{{service_name}}'/$service_name}"
    value="${value//'{{compose_dir}}'/$compose_dir}"
    value="${value//'{{unit_name}}'/$unit_name}"
    printf '%s' "$value"
}

validate_configuration() {
    local version value value_type count index key source_name
    [[ -f "$CONFIG_FILE" ]] || die "config_not_found file=${CONFIG_FILE}"
    command -v yq >/dev/null 2>&1 || die 'yq_v4_required'
    version="$(yq --version 2>/dev/null)" || die 'yq_version_unavailable'
    [[ "$version" =~ version[[:space:]]+v?4\. ]] || die 'yq_v4_required'
    yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1 || die "invalid_yaml file=${CONFIG_FILE}"
    [[ "$(read_config '.discovery | type')" == '!!map' ]] || die 'discovery_must_be_a_map'
    [[ "$(read_config '.discovery.enabled | type')" == '!!bool' ]] || die 'discovery.enabled_must_be_boolean'
    value="$(read_config '.discovery.enabled // false')"
    [[ "$value" == true ]] || die 'discovery_disabled_set_discovery.enabled_true'
    value_type="$(read_config '.discovery.output_dir | type')"
    [[ "$value_type" == '!!null' || "$value_type" == '!!str' ]] || die 'discovery.output_dir_must_be_string'
    OUTPUT_DIR="$(read_config '.discovery.output_dir // ""')"
    if [[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != /* ]]; then die 'discovery.output_dir_must_be_absolute'; fi
    value_type="$(read_config '.discovery.output_prefix | type')"
    [[ "$value_type" == '!!null' || "$value_type" == '!!str' ]] || die 'discovery.output_prefix_must_be_string'
    OUTPUT_PREFIX="$(read_config '.discovery.output_prefix // "auto-"')"
    [[ "$OUTPUT_PREFIX" =~ ^[A-Za-z0-9._-]+$ && "$OUTPUT_PREFIX" != . && "$OUTPUT_PREFIX" != .. ]] ||
        die 'discovery.output_prefix_invalid'
    OUTPUT_FILE="${OUTPUT_PREFIX}discovery.yaml"

    for source_name in docker_compose systemd; do
        value_type="$(read_config ".discovery.${source_name}.enabled | type")"
        [[ "$value_type" == '!!null' || "$value_type" == '!!bool' ]] || die "discovery.${source_name}.enabled_must_be_boolean"
        value="$(read_config ".discovery.${source_name}.enabled // false")"
        [[ "$value" == true || "$value" == false ]] || die "discovery.${source_name}.enabled_must_be_boolean"
        value_type="$(read_config ".discovery.${source_name}.sources | type")"
        [[ "$value_type" == '!!null' || "$value_type" == '!!seq' ]] || die "discovery.${source_name}.sources_must_be_array"
        count="$(read_config ".discovery.${source_name}.sources // [] | length")"
        for ((index = 0; index < count; index++)); do
            [[ "$(read_config ".discovery.${source_name}.sources[$index] | type")" == '!!str' ]] ||
                die "discovery.${source_name}.sources[$index]_must_be_string"
        done
    done
    [[ "$(read_config '.discovery.docker_compose.enabled // false')" == true ]] && DOCKER_ENABLED=1
    [[ "$(read_config '.discovery.systemd.enabled // false')" == true ]] && SYSTEMD_ENABLED=1
    [[ "$SOURCE_FILTER" != docker ]] || SYSTEMD_ENABLED=0
    [[ "$SOURCE_FILTER" != systemd ]] || DOCKER_ENABLED=0
    (( DOCKER_ENABLED == 1 || SYSTEMD_ENABLED == 1 )) || die 'no_enabled_discovery_sources'

    value_type="$(read_config '.discovery.docker_compose.only_with_healthcheck | type')"
    [[ "$value_type" == '!!null' || "$value_type" == '!!bool' ]] || die 'discovery.docker_compose.only_with_healthcheck_must_be_boolean'
    value="$(read_config '.discovery.docker_compose.only_with_healthcheck // false')"
    [[ "$value" == true || "$value" == false ]] || die 'discovery.docker_compose.only_with_healthcheck_must_be_boolean'
    [[ "$value" != true ]] || ONLY_WITH_HEALTHCHECK=1
    value_type="$(read_config '.discovery.systemd.detect_ports | type')"
    [[ "$value_type" == '!!null' || "$value_type" == '!!bool' ]] || die 'discovery.systemd.detect_ports_must_be_boolean'
    value="$(read_config '.discovery.systemd.detect_ports // true')"
    # yq's // operator treats false as absent; read it directly when present.
    if [[ "$(read_config '.discovery.systemd.detect_ports | type')" != '!!null' ]]; then
        value="$(read_config '.discovery.systemd.detect_ports')"
    fi
    [[ "$value" == true || "$value" == false ]] || die 'discovery.systemd.detect_ports_must_be_boolean'
    [[ "$value" != false ]] || DETECT_PORTS=0

    for key in docker_compose.skip_labels docker_compose.http_ports systemd.only_service_types systemd.skip_patterns; do
        value_type="$(read_config ".discovery.${key} | type")"
        [[ "$value_type" == '!!null' || "$value_type" == '!!seq' ]] || die "discovery.${key}_must_be_array"
    done
    count="$(read_config '.discovery.docker_compose.http_ports // [] | length')"
    for ((index = 0; index < count; index++)); do
        value="$(read_config ".discovery.docker_compose.http_ports[$index]")"
        if ! is_positive_integer "$value" || (( 10#$value > 65535 )); then
            die "discovery.docker_compose.http_ports[$index]_invalid"
        fi
    done
    for key in docker_compose systemd; do
        value_type="$(read_config ".discovery.${key}.default_actions | type")"
        [[ "$value_type" == '!!null' || "$value_type" == '!!map' ]] || die "discovery.${key}.default_actions_must_be_map"
    done
}

is_http_port() {
    local port="$1" count index candidate
    count="$(read_config '.discovery.docker_compose.http_ports | length')"
    if [[ "$(read_config '.discovery.docker_compose.http_ports | type')" == '!!null' ]]; then
        case "$port" in 80|443|8080|3000|8000|8081|8443) return 0 ;; *) return 1 ;; esac
    fi
    for ((index = 0; index < count; index++)); do
        candidate="$(read_config ".discovery.docker_compose.http_ports[$index]")"
        [[ "$candidate" != "$port" ]] || return 0
    done
    return 1
}

emit_actions() {
    local path="$1" service_name="$2" compose_dir="$3" unit_name="$4"
    local value value_type count command_index argument_count argument_index argument separator
    [[ "$(read_config "${path} | type")" == '!!map' ]] || return 0
    printf '    actions:\n'
    for value in cooldown verify_after; do
        value_type="$(read_config "${path}.${value} | type")"
        [[ "$value_type" == '!!null' ]] && continue
        argument="$(read_config "${path}.${value}")"
        is_non_negative_integer "$argument" || die "${path}.${value}_must_be_non_negative_integer"
        printf '      %s: %s\n' "$value" "$argument"
    done
    value_type="$(read_config "${path}.commands | type")"
    [[ "$value_type" == '!!null' ]] && return 0
    [[ "$value_type" == '!!seq' ]] || die "${path}.commands_must_be_array"
    count="$(read_config "${path}.commands | length")"
    (( count > 0 )) || die "${path}.commands_must_not_be_empty"
    printf '      commands:\n'
    for ((command_index = 0; command_index < count; command_index++)); do
        value_type="$(read_config "${path}.commands[$command_index].command | type")"
        [[ "$value_type" == '!!seq' ]] || die "${path}.commands[$command_index].command_must_be_array"
        argument_count="$(read_config "${path}.commands[$command_index].command | length")"
        (( argument_count > 0 )) || die "${path}.commands[$command_index].command_must_not_be_empty"
        printf '        - command: ['
        separator=''
        for ((argument_index = 0; argument_index < argument_count; argument_index++)); do
            argument="$(read_config "${path}.commands[$command_index].command[$argument_index]")"
            argument="$(expand_action_value "$argument" "$service_name" "$compose_dir" "$unit_name")"
            printf '%s%s' "$separator" "$(yaml_quote "$argument")"
            separator=', '
        done
        printf ']\n'
        value_type="$(read_config "${path}.commands[$command_index].working_directory | type")"
        if [[ "$value_type" != '!!null' ]]; then
            argument="$(read_config "${path}.commands[$command_index].working_directory")"
            argument="$(expand_action_value "$argument" "$service_name" "$compose_dir" "$unit_name")"
            printf '          working_directory: %s\n' "$(yaml_quote "$argument")"
        fi
        value_type="$(read_config "${path}.commands[$command_index].timeout | type")"
        if [[ "$value_type" != '!!null' ]]; then
            argument="$(read_config "${path}.commands[$command_index].timeout")"
            is_positive_integer "$argument" || die "${path}.commands[$command_index].timeout_must_be_positive_integer"
            printf '          timeout: %s\n' "$argument"
        fi
    done
}

emit_service() {
    local name="$1" check_type="$2" endpoint="$3" action_path="$4" service_name="$5" compose_dir="$6" unit_name="$7"
    printf '  - name: %s\n' "$(yaml_quote "$name")"
    printf '    check:\n      type: %s\n' "$check_type"
    case "$check_type" in
        http) printf '      url: %s\n      timeout: 10\n      attempts: 3\n' "$(yaml_quote "$endpoint")" ;;
        tcp) printf '      host: localhost\n      port: %s\n      timeout: 10\n      attempts: 3\n' "$endpoint" ;;
        command) printf '      commands:\n        - command: [%s, %s, %s, %s]\n' \
            "$(yaml_quote systemctl)" "$(yaml_quote is-active)" "$(yaml_quote --quiet)" "$(yaml_quote "$unit_name")" ;;
    esac
    emit_actions "$action_path" "$service_name" "$compose_dir" "$unit_name"
    SERVICES_TOTAL=$((SERVICES_TOTAL + 1))
}

compose_read() {
    local file="$1" service_name="$2" expression="$3"
    DISCOVERY_SERVICE="$service_name" yq eval -r ".services[strenv(DISCOVERY_SERVICE)]${expression}" "$file"
}

compose_has_skip_label() {
    local file="$1" service_name="$2" count index filter key expected labels_type value label_count label_index
    count="$(read_config '.discovery.docker_compose.skip_labels // [] | length')"
    (( count > 0 )) || return 1
    labels_type="$(compose_read "$file" "$service_name" '.labels | type')"
    for ((index = 0; index < count; index++)); do
        filter="$(read_config ".discovery.docker_compose.skip_labels[$index]")"
        key="${filter%%=*}"
        expected="${filter#*=}"
        if [[ "$labels_type" == '!!map' ]]; then
            value="$(DISCOVERY_LABEL_KEY="$key" DISCOVERY_SERVICE="$service_name" \
                yq eval -r '.services[strenv(DISCOVERY_SERVICE)].labels[strenv(DISCOVERY_LABEL_KEY)]' "$file")"
            if [[ "$filter" == *=* ]]; then
                [[ "$value" != "$expected" ]] || return 0
            elif [[ "$value" != null ]]; then
                return 0
            fi
        elif [[ "$labels_type" == '!!seq' ]]; then
            label_count="$(compose_read "$file" "$service_name" '.labels | length')"
            for ((label_index = 0; label_index < label_count; label_index++)); do
                value="$(compose_read "$file" "$service_name" ".labels[$label_index]")"
                if [[ "$value" == "$filter" || ( "$filter" != *=* && "$value" == "$key="* ) ]]; then return 0; fi
            done
        fi
    done
    return 1
}

compose_published_port() {
    local file="$1" service_name="$2" index="$3" value_type value protocol host_ip published
    value_type="$(compose_read "$file" "$service_name" ".ports[$index] | type")"
    if [[ "$value_type" == '!!map' ]]; then
        protocol="$(compose_read "$file" "$service_name" ".ports[$index].protocol // \"tcp\"")"
        [[ "$protocol" == tcp ]] || return 1
        host_ip="$(compose_read "$file" "$service_name" ".ports[$index].host_ip // \"\"")"
        case "$host_ip" in ''|0.0.0.0|::|127.0.0.1|::1|localhost) ;; *) return 1 ;; esac
        published="$(compose_read "$file" "$service_name" ".ports[$index].published")"
    else
        value="$(compose_read "$file" "$service_name" ".ports[$index]")"
        [[ "$value" == *:* ]] || return 1
        [[ "$value" != */udp ]] || return 1
        value="${value%/tcp}"
        published="${value%:*}"
        if [[ "$published" == *:* ]]; then
            host_ip="${published%:*}"
            case "$host_ip" in 0.0.0.0|::|127.0.0.1|::1|'[::]'|'[::1]'|localhost) ;; *) return 1 ;; esac
        fi
        published="${published##*:}"
    fi
    if ! is_positive_integer "$published" || (( 10#$published > 65535 )); then return 1; fi
    printf '%s' "$published"
}

discover_docker_compose() {
    local compose_file="$1" service_name project_name compose_dir health_type health_test only_health
    local services_type ports_type port_count port_index port http_port='' tcp_port='' check_type endpoint
    local skipped=0 before="$SERVICES_TOTAL" service_count
    compose_file="$(realpath -e -- "$compose_file" 2>/dev/null)" || return 0
    [[ -z "${PROCESSED_COMPOSE[$compose_file]:-}" ]] || return 0
    PROCESSED_COMPOSE["$compose_file"]=1
    services_type="$(yq eval -r '.services | type' "$compose_file" 2>/dev/null)"
    if [[ "$services_type" != '!!map' ]]; then
        log_discovery "discovery=docker_compose file=${compose_file} action=skipped reason=missing_services_map"
        return 0
    fi
    compose_dir="$(dirname -- "$compose_file")"
    project_name="$(basename -- "$compose_dir")"
    service_count="$(yq eval -r '.services | length' "$compose_file")"
    while IFS= read -r service_name; do
        [[ -n "$service_name" ]] || continue
        health_type="$(compose_read "$compose_file" "$service_name" '.healthcheck | type')"
        health_test="$(compose_read "$compose_file" "$service_name" '.healthcheck.test | type')"
        only_health=0
        if [[ "$health_type" == '!!map' && "$health_test" != '!!null' &&
            "$(compose_read "$compose_file" "$service_name" '.healthcheck.disable // false')" != true ]]; then only_health=1; fi
        if (( ONLY_WITH_HEALTHCHECK == 1 && only_health == 0 )); then
            skipped=$((skipped + 1)); log_discovery "discovery=docker_compose service=${service_name} reason=no_healthcheck action=skipped"; continue
        fi
        if compose_has_skip_label "$compose_file" "$service_name"; then
            skipped=$((skipped + 1)); log_discovery "discovery=docker_compose service=${service_name} reason=skip_label action=skipped"; continue
        fi
        http_port=''; tcp_port=''
        ports_type="$(compose_read "$compose_file" "$service_name" '.ports | type')"
        if [[ "$ports_type" == '!!seq' ]]; then
            port_count="$(compose_read "$compose_file" "$service_name" '.ports | length')"
            for ((port_index = 0; port_index < port_count; port_index++)); do
                port="$(compose_published_port "$compose_file" "$service_name" "$port_index")" || continue
                if is_http_port "$port"; then
                    [[ -n "$http_port" ]] || http_port="$port"
                else
                    [[ -n "$tcp_port" ]] || tcp_port="$port"
                fi
            done
        fi
        if [[ -n "$http_port" ]]; then
            check_type=http; port="$http_port"
            if [[ "$port" == 443 || "$port" == 8443 ]]; then endpoint="https://localhost:${port}"; else endpoint="http://localhost:${port}"; fi
        elif [[ -n "$tcp_port" ]]; then
            check_type=tcp; port="$tcp_port"; endpoint="$port"
        else
            skipped=$((skipped + 1))
            log_discovery "discovery=docker_compose service=${service_name} reason=no_published_tcp_port action=skipped"
            continue
        fi
        unique_name "${project_name}-${service_name}"
        emit_service "$UNIQUE_NAME" "$check_type" "$endpoint" '.discovery.docker_compose.default_actions' \
            "$service_name" "$compose_dir" ''
        log_discovery "discovery=docker_compose service=${service_name} check_type=${check_type} port=${port} action=generated"
    done < <(yq eval -r '.services | keys | .[]' "$compose_file")
    log_discovery "discovery=docker_compose file=${compose_file} services_found=${service_count} services_generated=$((SERVICES_TOTAL - before)) services_skipped=${skipped}"
}

scan_compose_source() {
    local source="$1" candidate
    if [[ -f "$source" ]]; then
        discover_docker_compose "$source"
        return 0
    fi
    if [[ -d "$source" ]]; then
        for candidate in docker-compose.yml compose.yml docker-compose.yaml compose.yaml; do
            if [[ -f "${source%/}/${candidate}" ]]; then
                discover_docker_compose "${source%/}/${candidate}"
                return 0
            fi
        done
    fi
    log_discovery "discovery=docker_compose source=${source} action=skipped reason=source_not_found"
}

systemd_type_allowed() {
    local unit_type="$1" count index candidate
    if [[ "$(read_config '.discovery.systemd.only_service_types | type')" == '!!null' ]]; then
        case "$unit_type" in simple|notify|forking) return 0 ;; *) return 1 ;; esac
    fi
    count="$(read_config '.discovery.systemd.only_service_types | length')"
    for ((index = 0; index < count; index++)); do
        candidate="$(read_config ".discovery.systemd.only_service_types[$index]")"
        [[ "$candidate" != "$unit_type" ]] || return 0
    done
    return 1
}

systemd_name_skipped() {
    local unit_name="$1" count index pattern
    [[ "$unit_name" != *'@'* && "$unit_name" != *watchdog* ]] || return 0
    count="$(read_config '.discovery.systemd.skip_patterns // [] | length')"
    for ((index = 0; index < count; index++)); do
        pattern="$(read_config ".discovery.systemd.skip_patterns[$index]")"
        [[ -z "$pattern" || "$unit_name" != *"$pattern"* ]] || return 0
    done
    return 1
}

detect_systemd_port() {
    local exec_start="$1" port=''
    if [[ "$exec_start" =~ --(http-)?port[=[:space:]]+([0-9]{2,5})([^0-9]|$) ]]; then
        port="${BASH_REMATCH[2]}"
    elif [[ "$exec_start" =~ (^|[[:space:]])-p[=[:space:]]*([0-9]{2,5})([^0-9]|$) ]]; then
        port="${BASH_REMATCH[2]}"
    elif [[ "$exec_start" =~ :([0-9]{2,5})([^0-9]|$) ]]; then
        port="${BASH_REMATCH[1]}"
    fi
    if ! is_positive_integer "$port" || (( 10#$port > 65535 )); then return 1; fi
    printf '%s' "$port"
}

discover_systemd_unit() {
    local unit_file="$1" unit_name section='' line unit_type=simple exec_start='' port='' check_type endpoint
    unit_file="$(realpath -e -- "$unit_file" 2>/dev/null)" || return 0
    [[ "$unit_file" == *.service ]] || { log_discovery "discovery=systemd file=${unit_file} action=skipped reason=not_service_unit"; return 0; }
    [[ -z "${PROCESSED_UNITS[$unit_file]:-}" ]] || return 0
    PROCESSED_UNITS["$unit_file"]=1
    unit_name="$(basename -- "$unit_file")"
    if systemd_name_skipped "$unit_name"; then
        log_discovery "discovery=systemd unit=${unit_name} action=skipped reason=skip_pattern"; return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\] ]]; then
            section="${BASH_REMATCH[1]}"; continue
        fi
        [[ "$section" == Service ]] || continue
        if [[ "$line" =~ ^[[:space:]]*Type[[:space:]]*=[[:space:]]*([^[:space:]#;]+) ]]; then
            unit_type="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            exec_start="${BASH_REMATCH[1]}"
        fi
    done <"$unit_file"
    if ! systemd_type_allowed "$unit_type"; then
        log_discovery "discovery=systemd unit=${unit_name} action=skipped reason=type_${unit_type}"; return 0
    fi
    check_type='command'; endpoint=''
    if (( DETECT_PORTS == 1 )) && [[ -n "$exec_start" ]]; then
        port="$(detect_systemd_port "$exec_start")" || port=''
        if [[ -n "$port" ]]; then
            if is_http_port "$port"; then
                check_type=http
                if [[ "$port" == 443 || "$port" == 8443 ]]; then endpoint="https://localhost:${port}"; else endpoint="http://localhost:${port}"; fi
            else
                check_type=tcp; endpoint="$port"
            fi
        fi
    fi
    unique_name "${unit_name%.service}"
    emit_service "$UNIQUE_NAME" "$check_type" "$endpoint" '.discovery.systemd.default_actions' \
        '' '' "$unit_name"
    log_discovery "discovery=systemd unit=${unit_name} check_type=${check_type} port=${port:-none} action=generated"
}

scan_systemd_source() {
    local source="$1" path directory found=0
    if [[ -f "$source" ]]; then
        discover_systemd_unit "$source"
        return 0
    fi
    if [[ -d "$source" ]]; then
        for path in "${source%/}/"*.service; do
            [[ -f "$path" ]] || continue
            found=1; discover_systemd_unit "$path"
        done
    elif [[ "$source" == */* ]]; then
        while IFS= read -r path; do
            [[ -f "$path" ]] || continue
            found=1; discover_systemd_unit "$path"
        done < <(compgen -G "$source" || true)
    else
        for directory in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system /run/systemd/system; do
            [[ -d "$directory" ]] || continue
            while IFS= read -r path; do
                [[ -f "$path" ]] || continue
                found=1; discover_systemd_unit "$path"
            done < <(compgen -G "${directory}/${source}" || true)
        done
        if (( found == 0 )) && command -v systemctl >/dev/null 2>&1 && [[ "$source" != *'*'* ]]; then
            path="$(systemctl show --property=FragmentPath --value "$source" 2>/dev/null)" || path=''
            if [[ -f "$path" ]]; then found=1; discover_systemd_unit "$path"; fi
        fi
    fi
    (( found == 1 )) || log_discovery "discovery=systemd source=${source} action=skipped reason=source_not_found"
}

write_discovery_output() {
    local target="$1" temporary
    if [[ -e "$target" || -L "$target" ]] && (( FORCE == 0 )); then
        log_discovery "discovery=output file=${target} action=skipped reason=file_exists"
        return 0
    fi
    mkdir -p -- "$OUTPUT_DIR" || die "output_directory_unavailable path=${OUTPUT_DIR}"
    temporary="$(mktemp "${OUTPUT_DIR%/}/.${OUTPUT_FILE}.XXXXXX")" || die 'output_temp_create_failed'
    if ! cat -- "$DISCOVERY_TEMP" >"$temporary"; then rm -f -- "$temporary"; die 'output_write_failed'; fi
    chmod 0640 "$temporary" 2>/dev/null || true
    if (( FORCE == 1 )); then
        mv -f -- "$temporary" "$target" || { rm -f -- "$temporary"; die 'output_rename_failed'; }
    else
        mv -n -- "$temporary" "$target" || { rm -f -- "$temporary"; die 'output_rename_failed'; }
        if [[ -e "$temporary" ]]; then
            rm -f -- "$temporary"
            log_discovery "discovery=output file=${target} action=skipped reason=file_exists"
            return 0
        fi
    fi
    log_discovery "discovery=output file=${target} services_total=${SERVICES_TOTAL} action=written"
}

discover_all() {
    local count index source
    DISCOVERY_TEMP="$(mktemp)" || die 'temporary_file_failed'
    printf 'services:\n' >"$DISCOVERY_TEMP"
    if (( DOCKER_ENABLED == 1 )); then
        if ! command -v docker >/dev/null 2>&1; then
            log_discovery 'discovery=docker_compose warning=docker_cli_unavailable static_compose_parsing_continues=true'
        fi
        count="$(read_config '.discovery.docker_compose.sources // [] | length')"
        for ((index = 0; index < count; index++)); do
            source="$(read_config ".discovery.docker_compose.sources[$index]")"
            scan_compose_source "$source" >>"$DISCOVERY_TEMP"
        done
    fi
    if (( SYSTEMD_ENABLED == 1 )); then
        if ! command -v systemctl >/dev/null 2>&1; then
            log_discovery 'discovery=systemd warning=systemctl_unavailable unit_file_parsing_continues=true'
        fi
        count="$(read_config '.discovery.systemd.sources // [] | length')"
        for ((index = 0; index < count; index++)); do
            source="$(read_config ".discovery.systemd.sources[$index]")"
            scan_systemd_source "$source" >>"$DISCOVERY_TEMP"
        done
    fi
    if (( SERVICES_TOTAL == 0 )); then printf 'services: []\n' >"$DISCOVERY_TEMP"; fi
    yq eval '.' "$DISCOVERY_TEMP" >/dev/null 2>&1 || die 'generated_yaml_invalid'
    log_discovery "discovery=summary services_total=${SERVICES_TOTAL} dry_run=${DRY_RUN}"
    if (( DRY_RUN == 1 )) || [[ "$OUTPUT_FORMAT" == stdout || -z "$OUTPUT_DIR" ]]; then
        cat -- "$DISCOVERY_TEMP"
        log_discovery 'discovery=output target=stdout action=preview'
    else
        write_discovery_output "${OUTPUT_DIR%/}/${OUTPUT_FILE}"
    fi
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            -c|--config)
                (( $# >= 2 )) || die 'missing_config_argument'
                CONFIG_FILE="$2"; shift 2 ;;
            --source)
                (( $# >= 2 )) || die 'missing_source_argument'
                SOURCE_FILTER="$2"; shift 2 ;;
            --format)
                (( $# >= 2 )) || die 'missing_format_argument'
                OUTPUT_FORMAT="$2"; shift 2 ;;
            --dry-run|-n) DRY_RUN=1; shift ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown_option=$1" ;;
        esac
    done
    [[ "$SOURCE_FILTER" == all || "$SOURCE_FILTER" == docker || "$SOURCE_FILTER" == systemd ]] || die 'source_must_be_docker_or_systemd'
    [[ "$OUTPUT_FORMAT" == auto || "$OUTPUT_FORMAT" == stdout ]] || die 'format_must_be_stdout'
    validate_configuration
    discover_all
}

main "$@"
