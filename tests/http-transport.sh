#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() { rm -rf -- "$TEST_DIRECTORY"; }
trap cleanup EXIT
fail() { printf 'HTTP transport test failed: %s\n' "$1" >&2; exit 1; }

for command_name in bash yq flock timeout date dirname mktemp tail tr mv env awk; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

mkdir -p "$TEST_DIRECTORY/bin"
cat >"$TEST_DIRECTORY/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

config_file=''
while (( $# > 0 )); do
    printf '%s\n' "$1" >>"$WATCHDOG_HTTP_TRANSPORT_ARGS"
    if [[ "$1" == --config ]]; then
        shift
        printf '%s\n' "$1" >>"$WATCHDOG_HTTP_TRANSPORT_ARGS"
        config_file="$1"
    fi
    shift
done
[[ -z "$config_file" ]] || cat "$config_file" >>"$WATCHDOG_HTTP_TRANSPORT_CONFIGS"
printf '200\tapplication/json\t0.001'
CURL
chmod 0755 "$TEST_DIRECTORY/bin/curl"

export PATH="$TEST_DIRECTORY/bin:$PATH"
export WATCHDOG_HTTP_TRANSPORT_ARGS="$TEST_DIRECTORY/curl-args.log"
export WATCHDOG_HTTP_TRANSPORT_CONFIGS="$TEST_DIRECTORY/curl-configs.log"
export WD_PROXY_USERNAME='watchdog-proxy-user'
export WD_PROXY_PASSWORD='watchdog-proxy-secret'

for certificate_file in ca.pem client.crt client.key; do
    printf 'test-%s\n' "$certificate_file" >"$TEST_DIRECTORY/$certificate_file"
done
chmod 0600 "$TEST_DIRECTORY/client.key"

cat >"$TEST_DIRECTORY/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
templates:
  private-http:
    check:
      type: http
      proxy:
        url: http://proxy.example.test:8080
        username_env: WD_PROXY_USERNAME
        password_env: WD_PROXY_PASSWORD
      tls:
        ca_cert_file: ${TEST_DIRECTORY}/ca.pem
        client_cert_file: ${TEST_DIRECTORY}/client.crt
        client_key_file: ${TEST_DIRECTORY}/client.key
    actions: {commands: []}
services:
  - name: mtls-proxy
    template: private-http
    check:
      url: https://api.example.test/health
  - name: health-transport
    health:
      liveness:
        type: http
        url: https://api.example.test/live
        tls:
          ca_cert_file: ${TEST_DIRECTORY}/ca.pem
      readiness:
        type: http
        url: https://api.example.test/ready
        proxy:
          url: http://proxy.example.test:8080
    actions: {commands: []}
EOF

bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIRECTORY/config.yaml" >/dev/null ||
    fail 'valid mTLS/proxy configuration was rejected'
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/config.yaml" >/dev/null ||
    fail 'mTLS/proxy HTTP checks did not succeed'
[[ "$(<"$TEST_DIRECTORY/state/mtls-proxy.state")" == healthy ]] || fail 'mTLS/proxy state was not healthy'
[[ "$(<"$TEST_DIRECTORY/state/health-transport.state")" == healthy ]] || fail 'health transport state was not healthy'

for expected_argument in --cacert "$TEST_DIRECTORY/ca.pem" --cert "$TEST_DIRECTORY/client.crt" --key "$TEST_DIRECTORY/client.key" --proxy http://proxy.example.test:8080 --config; do
    grep -Fx -- "$expected_argument" "$WATCHDOG_HTTP_TRANSPORT_ARGS" >/dev/null ||
        fail "curl did not receive ${expected_argument}"
done
grep -Fx 'proxy-user = "watchdog-proxy-user:watchdog-proxy-secret"' "$WATCHDOG_HTTP_TRANSPORT_CONFIGS" >/dev/null ||
    fail 'proxy credentials were not written to the private curl config'
if grep -Fq 'watchdog-proxy-secret' "$WATCHDOG_HTTP_TRANSPORT_ARGS" "$TEST_DIRECTORY/watchdog.log" "$TEST_DIRECTORY/state/mtls-proxy.state"; then
    fail 'proxy password leaked to curl argv, logs, or state'
fi

cp "$TEST_DIRECTORY/config.yaml" "$TEST_DIRECTORY/missing-proxy-password.yaml"
yq eval -i '.templates.private-http.check.proxy.password_env = "WD_MISSING_PROXY_PASSWORD"' "$TEST_DIRECTORY/missing-proxy-password.yaml"
status=0
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIRECTORY/missing-proxy-password.yaml" -s mtls-proxy >/dev/null || status=$?
[[ "$status" == 1 ]] || fail "missing proxy password should fail the check, got ${status}"
grep -Fq 'missing HTTP proxy environment variable WD_MISSING_PROXY_PASSWORD' "$TEST_DIRECTORY/watchdog.log" ||
    fail 'missing proxy password did not identify its environment variable'

for invalid_case in missing-key proxy-auth proxy-credentials-in-url relative-ca; do
    cp "$TEST_DIRECTORY/config.yaml" "$TEST_DIRECTORY/${invalid_case}.yaml"
    case "$invalid_case" in
        missing-key) yq eval -i 'del(.templates.private-http.check.tls.client_key_file)' "$TEST_DIRECTORY/${invalid_case}.yaml" ;;
        proxy-auth) yq eval -i 'del(.templates.private-http.check.proxy.password_env)' "$TEST_DIRECTORY/${invalid_case}.yaml" ;;
        proxy-credentials-in-url) yq eval -i '.templates.private-http.check.proxy.url = "http://user:password@proxy.example.test:8080"' "$TEST_DIRECTORY/${invalid_case}.yaml" ;;
        relative-ca) yq eval -i '.templates.private-http.check.tls.ca_cert_file = "ca.pem"' "$TEST_DIRECTORY/${invalid_case}.yaml" ;;
    esac
    status=0
    bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIRECTORY/${invalid_case}.yaml" >"$TEST_DIRECTORY/${invalid_case}.out" 2>&1 || status=$?
    [[ "$status" == 2 ]] || fail "${invalid_case} should fail validation, got ${status}"
done

printf 'HTTP mTLS and proxy transport tests passed.\n'
