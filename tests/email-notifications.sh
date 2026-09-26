#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

for command_name in base64 flock timeout yq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

mkdir -p "${TEST_DIRECTORY}/bin"
cat >"${TEST_DIRECTORY}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

upload_file=""
auth_config=""
printf '%s\n' "$@" >"$WATCHDOG_TEST_CURL_ARGUMENTS"
while (( $# > 0 )); do
    case "$1" in
        --config)
            auth_config="$2"
            shift 2
            ;;
        --upload-file)
            upload_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "$upload_file" && -r "$upload_file" ]]
[[ -n "$auth_config" && -r "$auth_config" ]]
printf '%s\n' "$auth_config" >"$WATCHDOG_TEST_SMTP_AUTH_FILE"
stat -c '%a' "$auth_config" >"$WATCHDOG_TEST_SMTP_AUTH_MODE"
grep -Fqx "user = \"watchdog@example.test:${WATCHDOG_TEST_SMTP_PASSWORD}\"" "$auth_config"
if [[ "${WATCHDOG_TEST_CURL_FAIL:-0}" == 1 ]]; then
    printf 'curl: SMTP authentication failed for %s\n' "$WATCHDOG_TEST_SMTP_PASSWORD" >&2
    exit 7
fi
printf '%s\n' '--- MESSAGE ---' >>"$WATCHDOG_TEST_MAILBOX"
cat -- "$upload_file" >>"$WATCHDOG_TEST_MAILBOX"
FAKE_CURL
chmod 0755 "${TEST_DIRECTORY}/bin/curl"

cat >"${TEST_DIRECTORY}/bin/remediate" <<'REMEDIATE'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f "$WATCHDOG_TEST_ALLOW_RECOVERY" ]]; then
    touch "$WATCHDOG_TEST_HEALTHY_FILE"
fi
REMEDIATE
chmod 0755 "${TEST_DIRECTORY}/bin/remediate"

export PATH="${TEST_DIRECTORY}/bin:${PATH}"
export WATCHDOG_TEST_MAILBOX="${TEST_DIRECTORY}/mailbox.eml"
export WATCHDOG_TEST_ALLOW_RECOVERY="${TEST_DIRECTORY}/allow-recovery"
export WATCHDOG_TEST_HEALTHY_FILE="${TEST_DIRECTORY}/healthy"
export WATCHDOG_TEST_CURL_ARGUMENTS="${TEST_DIRECTORY}/curl-arguments"
export WATCHDOG_TEST_SMTP_AUTH_FILE="${TEST_DIRECTORY}/smtp-auth-file"
export WATCHDOG_TEST_SMTP_AUTH_MODE="${TEST_DIRECTORY}/smtp-auth-mode"
export WATCHDOG_TEST_SMTP_PASSWORD='smtp-password-not-for-logs'

cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_timeout: 2
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 5
  default_action_cooldown: 0

notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.test:465
      from: watchdog@example.test
      username: watchdog@example.test
      password_env: WATCHDOG_TEST_SMTP_PASSWORD
      tls_required: true
      insecure_skip_verify: false
      timeout: 5
    recipients:
      - operator@example.test
    failure:
      subject: "FAILURE {{service}}"
      body: "failure event={{event}} action={{action_status}} detail={{detail}}"
    recovery:
      subject: "RECOVERY {{service}}"
      body: "recovery event={{event}} action={{action_status}} detail={{detail}}"

services:
  - name: email-transition
    check:
      type: command
      attempts: 1
      retry_delay: 0
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
    actions:
      cooldown: 0
      verify_after: 0
      commands:
        - command: [remediate]
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
first_status=$?
set -e

[[ "$first_status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/email-transition.state")" == unavailable ]]
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 1 ]]
grep -F 'action=email event=failure' "${TEST_DIRECTORY}/watchdog.log" >/dev/null
[[ "$(<"$WATCHDOG_TEST_SMTP_AUTH_MODE")" == 600 ]]
smtp_auth_file="$(<"$WATCHDOG_TEST_SMTP_AUTH_FILE")"
[[ ! -e "$smtp_auth_file" ]]
if grep -Fq "$WATCHDOG_TEST_SMTP_PASSWORD" "$WATCHDOG_TEST_CURL_ARGUMENTS" "${TEST_DIRECTORY}/watchdog.log"; then
    printf 'SMTP password leaked to curl arguments or operational log.\n' >&2
    exit 1
fi

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
second_status=$?
set -e

[[ "$second_status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/email-transition.state")" == unavailable ]]
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 1 ]]

touch "$WATCHDOG_TEST_ALLOW_RECOVERY"
set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
third_status=$?
set -e

[[ "$third_status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/email-transition.state")" == healthy ]]
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 2 ]]
grep -F 'action=email event=recovery' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 2 ]]

rm -f -- "$WATCHDOG_TEST_ALLOW_RECOVERY" "$WATCHDOG_TEST_HEALTHY_FILE"
set +e
WATCHDOG_TEST_CURL_FAIL=1 bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
failed_delivery_status=$?
set -e
[[ "$failed_delivery_status" == 1 ]]
grep -F 'result=email-failed' "${TEST_DIRECTORY}/watchdog.log" >/dev/null
if grep -Fq "$WATCHDOG_TEST_SMTP_PASSWORD" "${TEST_DIRECTORY}/watchdog.log"; then
    printf 'SMTP password leaked through curl error output.\n' >&2
    exit 1
fi

cp "${TEST_DIRECTORY}/config.yaml" "${TEST_DIRECTORY}/invalid-smtp-username.yaml"
yq eval -i '.notifications.email.smtp.username = "watchdog@example.test\ninjected"' \
    "${TEST_DIRECTORY}/invalid-smtp-username.yaml"
set +e
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/invalid-smtp-username.yaml" \
    >"${TEST_DIRECTORY}/invalid-smtp-username.out" 2>&1
invalid_username_status=$?
set -e
[[ "$invalid_username_status" == 2 ]]
grep -F 'notifications.email.smtp.username' "${TEST_DIRECTORY}/invalid-smtp-username.out" >/dev/null

set +e
cp "${TEST_DIRECTORY}/config.yaml" "${TEST_DIRECTORY}/invalid-smtp-password.yaml"
yq eval -i 'del(.notifications.email.smtp.password_env) | .notifications.email.smtp.password = "smtp-password\ninjected"' \
    "${TEST_DIRECTORY}/invalid-smtp-password.yaml"
bash "$WATCHDOG_SCRIPT" validate -c "${TEST_DIRECTORY}/invalid-smtp-password.yaml" \
    >"${TEST_DIRECTORY}/invalid-smtp-password.out" 2>&1
invalid_password_status=$?
set -e
[[ "$invalid_password_status" == 2 ]]
grep -F 'notifications.email.smtp.password' "${TEST_DIRECTORY}/invalid-smtp-password.out" >/dev/null
if grep -Fq 'smtp-password' "${TEST_DIRECTORY}/invalid-smtp-password.out"; then
    printf 'Invalid SMTP password leaked to validation output.\n' >&2
    exit 1
fi

set +e
WATCHDOG_TEST_SMTP_PASSWORD=$'smtp-password\ninjected' \
    bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition \
    >"${TEST_DIRECTORY}/invalid-smtp-password-env.out" 2>&1
invalid_password_env_status=$?
set -e
[[ "$invalid_password_env_status" == 2 ]]
grep -F 'notifications.email.smtp.password' "${TEST_DIRECTORY}/watchdog.log" >/dev/null
if grep -Fq 'smtp-password' "${TEST_DIRECTORY}/invalid-smtp-password-env.out" "${TEST_DIRECTORY}/watchdog.log"; then
    printf 'Invalid SMTP environment password leaked to output or log.\n' >&2
    exit 1
fi

printf 'Email notification test passed.\n'
