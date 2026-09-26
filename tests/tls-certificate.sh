#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { printf 'tls-certificate test failed: %s\n' "$1" >&2; exit 1; }

for command_name in base64 flock timeout yq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

ORIGINAL_PATH="$PATH"
WATCHDOG_REAL_DATE="$(command -v date)"
export WATCHDOG_REAL_DATE
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/no-openssl"
cat >"$TEST_DIR/bin/openssl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

subcommand="${1:-}"
shift || true
case "$subcommand" in
    s_client)
        printf '%s\n' "$@" >"$TLS_TEST_SCLIENT_ARGS"
        if [[ "${TLS_TEST_OPENSSL_MODE:-healthy}" == unavailable ]]; then
            printf 'connect: Connection refused\n' >&2
            exit 1
        fi
        printf '%s\n' '-----BEGIN CERTIFICATE-----' 'test-certificate' '-----END CERTIFICATE-----'
        ;;
    x509)
        cat >/dev/null
        case "${TLS_TEST_OPENSSL_MODE:-healthy}" in
            invalid_expiry) printf 'notAfter=not-a-date\n' ;;
            expired) expiry_epoch=$(( $("$WATCHDOG_REAL_DATE" '+%s') - 3600 )) ;;
            expiring) expiry_epoch=$(( $("$WATCHDOG_REAL_DATE" '+%s') + 2 * 86400 )) ;;
            healthy) expiry_epoch=$(( $("$WATCHDOG_REAL_DATE" '+%s') + 45 * 86400 )) ;;
            *) exit 2 ;;
        esac
        if [[ "${TLS_TEST_OPENSSL_MODE:-healthy}" != invalid_expiry ]]; then
            "$WATCHDOG_REAL_DATE" -u -d "@${expiry_epoch}" '+notAfter=%b %e %H:%M:%S %Y GMT'
        fi
        ;;
    *)
        printf 'unexpected openssl subcommand: %s\n' "$subcommand" >&2
        exit 2
        ;;
esac
SHIM
chmod +x "$TEST_DIR/bin/openssl"
export PATH="$TEST_DIR/bin:$PATH"
export TLS_TEST_SCLIENT_ARGS="$TEST_DIR/s-client-arguments"

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
  default_attempts: 1
  default_retry_delay: 0
notifications:
  email:
    enabled: false
services:
  - name: public-api-tls
    check:
      type: tls_cert
      host: edge.example.test
      port: 8443
      server_name: api.example.test
      min_days_remaining: 21
      timeout: 2
YAML

bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" >/dev/null || fail 'valid TLS config rejected'
[[ ! -s "$TLS_TEST_SCLIENT_ARGS" && ! -e "$TEST_DIR/state" ]] || fail 'validate contacted TLS endpoint or created state'

TLS_TEST_OPENSSL_MODE=healthy bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || fail 'healthy TLS certificate rejected'
[[ "$(<"$TEST_DIR/state/public-api-tls.state")" == healthy ]] || fail 'healthy TLS state missing'
grep -Fx -- '-connect' "$TLS_TEST_SCLIENT_ARGS" >/dev/null || fail 'openssl did not receive -connect'
grep -Fx -- 'edge.example.test:8443' "$TLS_TEST_SCLIENT_ARGS" >/dev/null || fail 'TLS endpoint arguments missing'
grep -Fx -- '-servername' "$TLS_TEST_SCLIENT_ARGS" >/dev/null || fail 'openssl did not receive SNI'
grep -Fx -- 'api.example.test' "$TLS_TEST_SCLIENT_ARGS" >/dev/null || fail 'TLS SNI argument missing'
grep -Fq 'days_remaining=' "$TEST_DIR/watchdog.log" || fail 'TLS expiry detail missing'
if grep -Fq 'BEGIN CERTIFICATE' "$TEST_DIR/watchdog.log"; then fail 'certificate data leaked to log'; fi

cp "$TEST_DIR/config.yaml" "$TEST_DIR/defaults.yaml"
yq eval -i 'del(.services[0].check.port, .services[0].check.server_name)' "$TEST_DIR/defaults.yaml"
TLS_TEST_OPENSSL_MODE=healthy bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/defaults.yaml" >/dev/null ||
    fail 'default TLS port and SNI were rejected'
grep -Fx -- 'edge.example.test:443' "$TLS_TEST_SCLIENT_ARGS" >/dev/null || fail 'default TLS port missing'
grep -Fx -- 'edge.example.test' "$TLS_TEST_SCLIENT_ARGS" >/dev/null || fail 'default TLS SNI missing'

status=0
TLS_TEST_OPENSSL_MODE=expiring bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || status=$?
[[ "$status" == 1 ]] || fail "expiring certificate should exit 1, got ${status}"
[[ "$(<"$TEST_DIR/state/public-api-tls.state")" == unavailable ]] || fail 'expiring TLS state missing'
grep -Fq 'certificate expiring soon' "$TEST_DIR/watchdog.log" || fail 'expiring certificate detail missing'

TLS_TEST_OPENSSL_MODE=healthy bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || fail 'TLS recovery rejected'
[[ "$(<"$TEST_DIR/state/public-api-tls.state")" == healthy ]] || fail 'TLS recovery state missing'

status=0
TLS_TEST_OPENSSL_MODE=expiring bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" -n >/dev/null || status=$?
[[ "$status" == 1 ]] || fail 'dry-run should report an expiring certificate'
[[ "$(<"$TEST_DIR/state/public-api-tls.state")" == healthy ]] || fail 'dry-run changed TLS state'

for mode in expired unavailable invalid_expiry; do
    status=0
    TLS_TEST_OPENSSL_MODE="$mode" bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" >/dev/null || status=$?
    [[ "$status" == 1 ]] || fail "${mode} certificate should exit 1"
done
grep -Fq 'reason=expired' "$TEST_DIR/watchdog.log" || fail 'expired certificate detail missing'
grep -Fq 'reason=certificate-unavailable' "$TEST_DIR/watchdog.log" || fail 'unavailable certificate detail missing'
grep -Fq 'reason=invalid-expiry' "$TEST_DIR/watchdog.log" || fail 'invalid expiry detail missing'

for invalid_case in missing_threshold invalid_host invalid_port invalid_server_name high_threshold; do
    cp "$TEST_DIR/config.yaml" "$TEST_DIR/invalid.yaml"
    case "$invalid_case" in
        missing_threshold) yq eval -i 'del(.services[0].check.min_days_remaining)' "$TEST_DIR/invalid.yaml" ;;
        invalid_host) yq eval -i '.services[0].check.host = "edge example.test"' "$TEST_DIR/invalid.yaml" ;;
        invalid_port) yq eval -i '.services[0].check.port = 70000' "$TEST_DIR/invalid.yaml" ;;
        invalid_server_name) yq eval -i '.services[0].check.server_name = "api example.test"' "$TEST_DIR/invalid.yaml" ;;
        high_threshold) yq eval -i '.services[0].check.min_days_remaining = 36501' "$TEST_DIR/invalid.yaml" ;;
    esac
    status=0
    bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/invalid.yaml" >"$TEST_DIR/invalid.out" 2>&1 || status=$?
    [[ "$status" == 2 ]] || fail "${invalid_case} should fail validation"
    grep -Fq 'services[0].check' "$TEST_DIR/invalid.out" || fail "${invalid_case} error lacks field path"
done

for command_name in bash base64 curl yq flock timeout date dirname mktemp tail tr mv env awk df hostname find; do
    ln -s "$(command -v "$command_name")" "$TEST_DIR/no-openssl/$command_name"
done
status=0
PATH="$TEST_DIR/no-openssl" bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" \
    >"$TEST_DIR/missing-openssl.out" 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "missing openssl should fail validation, got ${status}"
grep -Fq 'services[0].check.type=tls_cert requires openssl in PATH' "$TEST_DIR/missing-openssl.out" ||
    fail 'missing openssl error was not actionable'

export PATH="$ORIGINAL_PATH"
printf 'TLS certificate tests passed.\n'
