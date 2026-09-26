# Universal one-shot watchdog for HTTP, TCP, command, disk, TLS certificate, and security checks.
# Requires Bash >= 4.3, curl, yq v4, flock, and GNU timeout/coreutils.

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
WATCHDOG_VERSION="unknown"
if [[ -r "${SCRIPT_DIR}/VERSION" ]]; then
    IFS= read -r WATCHDOG_VERSION <"${SCRIPT_DIR}/VERSION" || true
    WATCHDOG_VERSION="${WATCHDOG_VERSION%$'\r'}"
fi
readonly WATCHDOG_VERSION

CONFIG_FILE="${WATCHDOG_CONFIG:-${SCRIPT_DIR}/config.yaml}"
ONLY_SERVICE=""
DRY_RUN=0
VALIDATE_ONLY=0
COMMAND_MODE=monitor
STATUS_JSON=0
STATUS_ALL=0
STATUS_CONFIG_CONTENT=""

# The monitor reads the same configuration paths throughout validation and a
# run. Keep scalar values, node tags, lengths, and map entry order in memory
# after a single yq traversal. The cache is deliberately best-effort: complex
# expressions and unsupported YAML shapes retain the established yq behavior.
YAML_CACHE_ACTIVE=0
declare -A YAML_CACHE_TAG=()
declare -A YAML_CACHE_VALUE=()
declare -A YAML_CACHE_LENGTH=()
declare -A YAML_CACHE_KEYS=()
declare -A YAML_CACHE_UNSAFE_MAP=()
NOTIFY_TEST_MODE=0
NOTIFY_TEST_CHANNEL=all
NOTIFY_TEST_EVENT=failure
NOTIFY_TEST_DETAIL=""
HISTORY_COMMAND=""
HISTORY_ARGUMENT=""

LOG_FILE=""
LOCK_FILE=""
STATE_DIRECTORY=""
TEMP_DIRECTORY=""
EXPANDED_CONFIG_FILE=""

DEFAULT_TIMEOUT=10
DEFAULT_ATTEMPTS=2
DEFAULT_RETRY_DELAY=2
DEFAULT_ACTION_TIMEOUT=120
DEFAULT_ACTION_COOLDOWN=300

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
CURRENT_SERVICE=""
CURRENT_CHECK_TYPE=""
CHECK_CONFIG_PATH=""
FILESYSTEM_TOTAL_BYTES=0
FILESYSTEM_FREE_BYTES=0
FILESYSTEM_FREE_PERCENT=""
FILESYSTEM_FREE_GB=""
CURRENT_ACTION_STATUS="not-attempted"
INCIDENT_ID=""
INCIDENT_DURATION=0
INCIDENT_REMEDIATION_RESULT="not-attempted"
MAINTENANCE_ACTIVE=0
MAINTENANCE_WINDOW_NAME=""
ESCALATION_CONSECUTIVE_UNAVAILABLE=0
ESCALATION_COUNT=0
METRICS_ENABLED=0
METRICS_DIRECTORY=""
METRICS_FILENAME="watchdog.prom"
METRICS_PREFIX="watchdog"
STATUS_PAGE_ENABLED=0
STATUS_PAGE_DIRECTORY=""
STATUS_PAGE_HTML_FILENAME="index.html"
STATUS_PAGE_JSON_FILENAME=""
STATUS_PAGE_UPTIME_ENABLED=0
STATUS_PAGE_UPTIME_DAYS=30
STATUS_PAGE_UPTIME_BUCKETS=30
STATUS_PAGE_UPTIME_CUTOFF=0
STATUS_PAGE_UPTIME_BUCKET_SECONDS=0
declare -A STATUS_PAGE_UPTIME_STATE=()
declare -A STATUS_PAGE_UPTIME_EPOCH=()
declare -A STATUS_PAGE_UPTIME_OBSERVED=()
FEDERATION_AGENT_ENABLED=0
FEDERATION_HUB_ENABLED=0
FEDERATION_NODE_ID=""
FEDERATION_AGENT_TRANSPORT=""
FEDERATION_AGENT_HUB_URL=""
FEDERATION_AGENT_TOKEN_ENV=""
FEDERATION_AGENT_TIMEOUT=10
FEDERATION_AGENT_REPORT_PATH=""
FEDERATION_AGENT_HEARTBEAT=1
FEDERATION_HUB_INCOMING_DIRECTORY=""
FEDERATION_HUB_ARCHIVE_DIRECTORY=""
FEDERATION_HUB_MAX_REPORT_AGE=300
FEDERATION_HUB_ARCHIVE_RETENTION_DAYS=0
FEDERATION_HUB_STATE_FILE=""
FEDERATION_HUB_OVERALL_STATUS="unknown"
FEDERATION_HUB_UNHEALTHY_SERVICES=""
FEDERATION_HUB_OFFLINE_NODES=""
FEDERATION_STATE_CHANGED=0
PARALLEL_ENABLED=0
PARALLEL_MAX_JOBS=0
PARALLEL_TIMEOUT=0
PARALLEL_TEMP_BASE=""
PARALLEL_CHECK_MODE=0
PARALLEL_ATTEMPTS_MADE=0
PROCESS_RESULT="unknown"
HISTORY_ENABLED=0
HISTORY_STORAGE=jsonl
HISTORY_PATH=""
HISTORY_ROTATION_MODE=daily
HISTORY_MAX_AGE_DAYS=30
HISTORY_MAX_RECORDS=0
HISTORY_TREND_DOTS=60
HISTORY_NODE_ID=""
HISTORY_FIELDS=()
HISTORY_SERVICES=()
declare -A HISTORY_TIMESTAMP=()
declare -A HISTORY_STATE=()
declare -A HISTORY_CHECK_TYPE=()
declare -A HISTORY_DETAIL=()
declare -A HISTORY_HTTP_STATUS=()
declare -A HISTORY_CHECK_EXIT=()
declare -A HISTORY_ACTION_STATUS=()
declare -A HISTORY_DURATION=()
declare -A HISTORY_CHECKED=()
declare -A HISTORY_CHECK_DURATION=()
declare -A PRELOADED_CHECK_DURATION=()
declare -A PRELOADED_MATCH_COUNT=()
declare -A PRELOADED_THRESHOLD_VALUE=()
declare -A PRELOADED_THRESHOLD_COMPARATOR=()
declare -A PRELOADED_THRESHOLD_SINCE=()
declare -A SERVICE_INDEX=()
declare -A DEPENDENCY_NAMES=()
declare -A DEPENDENCY_REQUIRED=()
declare -A RESOLVED_STATE=()
declare -A SERVICE_LEVEL=()
declare -A PRELOADED_CHECK_STATE=()
declare -A PRELOADED_CHECK_DETAIL=()
declare -A PRELOADED_CHECK_HTTP_STATUS=()
declare -A PRELOADED_CHECK_HTTP_TOTAL_MS=()
declare -A PRELOADED_CHECK_HTTP_MAX_TOTAL_MS=()
declare -A PRELOADED_CHECK_EXIT_CODE=()
declare -A PRELOADED_CHECK_ATTEMPTS=()
declare -A CONDITION_SKIPPED=()
declare -A CONDITION_EVALUATED=()
SERVICE_ORDER=()
TEMPLATE_EXPANSION_LOG=()
TEMPLATE_WARNING_LOG=()

EMAIL_ENABLED=0
EMAIL_SMTP_URL=""
EMAIL_FROM=""
EMAIL_USERNAME=""
EMAIL_PASSWORD=""
EMAIL_TLS_REQUIRED=1
EMAIL_INSECURE_SKIP_VERIFY=0
EMAIL_TIMEOUT=30
EMAIL_RECIPIENTS_COUNT=0
EMAIL_FAILURE_SUBJECT=""
EMAIL_FAILURE_BODY=""
EMAIL_RECOVERY_SUBJECT=""
EMAIL_RECOVERY_BODY=""

ACTION_ATTEMPTED=0
UNHEALTHY_FOUND=0
CONDITION_DETAIL=""
CONDITION_ERROR=0

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} [-c /path/to/config.yaml] [-s service_name] [-n]
  ${SCRIPT_NAME} validate -c /path/to/config.yaml
  ${SCRIPT_NAME} notify-test [-c FILE] [-s SERVICE] [--channel email|telegram|discord|slack|ntfy|pagerduty|opsgenie|all] [--event failure|recovery|escalation]
  ${SCRIPT_NAME} status [-c FILE] [-s SERVICE] [--json] [--all]
  ${SCRIPT_NAME} --report daily|weekly|monthly [-c FILE]
  ${SCRIPT_NAME} --trend SERVICE [-c FILE]
  ${SCRIPT_NAME} -V | --version

Options:
  -c FILE   YAML configuration file.
  -s NAME   Check only one configured service.
  -n        Dry run: perform checks, but do not run actions, hooks, or write state.
  --dry-run  Long alias for -n.
  -V        Show version information.
  -h        Show this help.

Environment:
  WATCHDOG_CONFIG   Alternative default configuration path.
EOF
}

bootstrap_log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$*" >&2
}

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$*" >>"$LOG_FILE"
}

die() {
    local message="$1"
    if (( VALIDATE_ONLY == 0 )) && [[ -n "${LOG_FILE:-}" && -w "$LOG_FILE" ]]; then
        log CRITICAL "$message"
    else
        bootstrap_log CRITICAL "$message"
    fi
    exit 2
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
    if [[ -n "${TEMP_DIRECTORY:-}" && -d "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi
    if [[ -n "${EXPANDED_CONFIG_FILE:-}" && -f "$EXPANDED_CONFIG_FILE" ]]; then
        rm -f -- "$EXPANDED_CONFIG_FILE"
    fi
}

trap cleanup EXIT
trap 'die "Execution interrupted by signal."' HUP INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

yaml_cache_path() {
    local expression="$1" path
    local simple_path_pattern='^[.][A-Za-z0-9_.-]*([[][0-9]+[]][A-Za-z0-9_.-]*)*$'

    [[ "$expression" =~ $simple_path_pattern ]] || return 1
    path="${expression#.}"
    path="${path//./\/}"
    path="${path//[[]/\/}"
    path="${path//[]]/}"
    printf '%s' "$path"
}

yaml_cache_literal() {
    local literal="$1"

    case "$literal" in
        '""') printf '' ;;
        \"*\")
            (( ${#literal} >= 2 )) || return 1
            printf '%s' "${literal:1:${#literal}-2}"
            ;;
        true|false|null|\[\]|\{\}|[0-9]*|-[0-9]*) printf '%s' "$literal" ;;
        *) return 1 ;;
    esac
}

yaml_cache_value() {
    local path="$1" default_value="${2-}" tag encoded
    local has_default=0

    (( $# >= 2 )) && has_default=1
    tag="${YAML_CACHE_TAG[$path]:-}"
    encoded="${YAML_CACHE_VALUE[$path]:-}"
    if [[ -z "$tag" || "$tag" == '!!null' ]]; then
        if (( has_default == 1 )); then
            printf '%s' "$default_value"
        else
            printf 'null'
        fi
        return 0
    fi
    if [[ "$tag" == '!!bool' && "$encoded" == 'b:ZmFsc2U=' && $has_default == 1 ]]; then
        printf '%s' "$default_value"
        return 0
    fi
    [[ "$tag" != '!!map' && "$tag" != '!!seq' ]] || return 1
    [[ "$encoded" == b:* ]] || return 1
    printf '%s' "${encoded#b:}" | base64 --decode
}

yaml_cache_length() {
    local path="$1" default_value="${2-}" tag encoded value
    local has_default=0

    (( $# >= 2 )) && has_default=1
    tag="${YAML_CACHE_TAG[$path]:-}"
    encoded="${YAML_CACHE_VALUE[$path]:-}"
    if [[ -z "$tag" || "$tag" == '!!null' ||
        ( "$tag" == '!!bool' && "$encoded" == 'b:ZmFsc2U=' ) ]]; then
        (( has_default == 1 )) || { printf '0'; return 0; }
        value="$(yaml_cache_literal "$default_value")" || return 1
        case "$value" in
            '[]'|'{}'|null) printf '0' ;;
            *) printf '%s' "${#value}" ;;
        esac
        return 0
    fi
    printf '%s' "${YAML_CACHE_LENGTH[$path]:-0}"
}

yaml_cache_entry() {
    local map_path="$1" entry_index="$2" member="$3" want_type="$4"
    local entries entry key value_path tag
    local -a keys=()

    [[ "${YAML_CACHE_TAG[$map_path]:-}" == '!!map' ]] || return 1
    [[ -z "${YAML_CACHE_UNSAFE_MAP[$map_path]:-}" ]] || return 1
    entries="${YAML_CACHE_KEYS[$map_path]:-}"
    [[ -n "$entries" ]] || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] && keys+=("$entry")
    done <<<"$entries"
    (( entry_index < ${#keys[@]} )) || return 1
    key="${keys[$entry_index]}"
    if [[ "$member" == key ]]; then
        if [[ "$want_type" == true ]]; then printf '!!str'; else printf '%s' "$key"; fi
        return 0
    fi
    value_path="${map_path}/${key}"
    tag="${YAML_CACHE_TAG[$value_path]:-!!null}"
    if [[ "$want_type" == true ]]; then
        printf '%s' "$tag"
    else
        yaml_cache_value "$value_path"
    fi
}

yaml_read_cached() {
    local expression="$1" path base default_value member candidate_path want_type=false
    local default_length_pattern='^(.+) // (.+) \| length$'
    local type_pattern='^(.+) \| type$'
    local length_pattern='^(.+) \| length$'
    local default_pattern='^(.+) // (.+)$'
    local entry_pattern='^(.+) \| to_entries\[([0-9]+)\]\.(key|value)( \| type)?$'
    local has_pattern='^(.+) \| has\("([A-Za-z0-9._-]+)"\)$'

    (( YAML_CACHE_ACTIVE == 1 )) || return 1
    if [[ "$expression" =~ $default_length_pattern ]]; then
        base="${BASH_REMATCH[1]}"
        default_value="${BASH_REMATCH[2]}"
        path="$(yaml_cache_path "$base")" || return 1
        yaml_cache_length "$path" "$default_value"
        return
    fi
    if [[ "$expression" =~ $entry_pattern ]]; then
        base="${BASH_REMATCH[1]}"
        path="$(yaml_cache_path "$base")" || return 1
        member="${BASH_REMATCH[3]}"
        [[ -z "${BASH_REMATCH[4]}" ]] || want_type=true
        yaml_cache_entry "$path" "${BASH_REMATCH[2]}" "$member" "$want_type"
        return
    fi
    if [[ "$expression" =~ $has_pattern ]]; then
        base="${BASH_REMATCH[1]}"
        path="$(yaml_cache_path "$base")" || return 1
        candidate_path="${path}/${BASH_REMATCH[2]}"
        if [[ -z "${YAML_CACHE_TAG[$candidate_path]:-}" || "${YAML_CACHE_TAG[$candidate_path]:-}" == '!!null' ]]; then
            printf false
        else
            printf true
        fi
        return
    fi
    if [[ "$expression" =~ $type_pattern ]]; then
        base="${BASH_REMATCH[1]}"
        path="$(yaml_cache_path "$base")" || return 1
        printf '%s' "${YAML_CACHE_TAG[$path]:-!!null}"
        return
    fi
    if [[ "$expression" =~ $length_pattern ]]; then
        base="${BASH_REMATCH[1]}"
        path="$(yaml_cache_path "$base")" || return 1
        yaml_cache_length "$path"
        return
    fi
    if [[ "$expression" =~ $default_pattern ]]; then
        base="${BASH_REMATCH[1]}"
        default_value="$(yaml_cache_literal "${BASH_REMATCH[2]}")" || return 1
        path="$(yaml_cache_path "$base")" || return 1
        yaml_cache_value "$path" "$default_value"
        return
    fi
    path="$(yaml_cache_path "$expression")" || return 1
    yaml_cache_value "$path"
}

load_yaml_cache() {
    local cache_output cache_path cache_tag cache_value cache_length parent_path key
    # shellcheck disable=SC2016 # $node is evaluated by yq, not this shell.
    local cache_expression='.. | . as $node | [(path | map(tostring) | join("/")), ($node | tag), (($node | select(tag != "!!map" and tag != "!!seq") | tostring | @base64 | "b:" + .) // "n:"), ($node | length | tostring)] | @tsv'

    YAML_CACHE_ACTIVE=0
    YAML_CACHE_TAG=()
    YAML_CACHE_VALUE=()
    YAML_CACHE_LENGTH=()
    YAML_CACHE_KEYS=()
    YAML_CACHE_UNSAFE_MAP=()
    if [[ "$COMMAND_MODE" == status || "$COMMAND_MODE" == history ]] && [[ -n "$STATUS_CONFIG_CONTENT" ]]; then
        cache_output="$(printf '%s\n' "$STATUS_CONFIG_CONTENT" | yq eval -r "$cache_expression" - 2>/dev/null)" || return 0
    else
        cache_output="$(yq eval -r "$cache_expression" "$CONFIG_FILE" 2>/dev/null)" || return 0
    fi
    [[ -n "$cache_output" ]] || return 0

    while IFS=$'\t' read -r cache_path cache_tag cache_value cache_length; do
        [[ -n "$cache_path" ]] || continue
        if [[ ! "$cache_path" =~ ^[A-Za-z0-9_./-]+$ ]]; then
            if [[ "$cache_path" == */* ]]; then
                parent_path="${cache_path%/*}"
                [[ "$parent_path" =~ ^[A-Za-z0-9_./-]+$ ]] && YAML_CACHE_UNSAFE_MAP["$parent_path"]=1
            fi
            continue
        fi
        YAML_CACHE_TAG["$cache_path"]="$cache_tag"
        YAML_CACHE_VALUE["$cache_path"]="$cache_value"
        YAML_CACHE_LENGTH["$cache_path"]="$cache_length"
        [[ "$cache_path" == */* ]] || continue
        parent_path="${cache_path%/*}"
        key="${cache_path##*/}"
        [[ "${YAML_CACHE_TAG[$parent_path]:-}" == '!!map' ]] || continue
        if [[ -n "${YAML_CACHE_KEYS[$parent_path]:-}" ]]; then
            YAML_CACHE_KEYS["$parent_path"]+=$'\n'
        fi
        YAML_CACHE_KEYS["$parent_path"]+="$key"
    done <<<"$cache_output"
    YAML_CACHE_ACTIVE=1
}

yaml_read_uncached() {
    if [[ "$COMMAND_MODE" == status || "$COMMAND_MODE" == history ]] && [[ -n "$STATUS_CONFIG_CONTENT" ]]; then
        printf '%s\n' "$STATUS_CONFIG_CONTENT" | yq eval -r "$1" -
    else
        yq eval -r "$1" "$CONFIG_FILE"
    fi
}

yaml_read() {
    yaml_read_cached "$1" || yaml_read_uncached "$1"
}

yaml_read_true_default() {
    local value
    value="$(yaml_read "$1")"
    if [[ "$value" == null ]]; then
        printf true
    else
        printf '%s' "$value"
    fi
}

now_milliseconds() {
    local epoch_nanoseconds
    epoch_nanoseconds="$(date '+%s%N')"
    printf '%s' "$((10#$epoch_nanoseconds / 1000000))"
}

service_check_type() {
    local index="$1"
    if [[ "$(yaml_read ".services[$index].health | type")" == '!!map' ]]; then
        printf 'http'
    else
        yaml_read ".services[$index].check.type"
    fi
}
