#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { printf 'security test failed: %s\n' "$1" >&2; [[ ! -f "$TEST_DIR/watchdog.log" ]] || tail -n 25 "$TEST_DIR/watchdog.log" >&2; exit 1; }

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/uploads"
cat >"$TEST_DIR/bin/clamscan" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SECURITY_CLAM_ARGS"
path="${@: -1}"
if [[ "${SECURITY_MODE:-}" == scanner_error ]]; then printf 'clamscan: scanner failure\n' >&2; exit 2; fi
if grep -q 'EICAR-STANDARD-ANTIVIRUS-TEST-FILE' "$path/test.txt"; then
    printf '%s/test.txt: Eicar-Test-Signature FOUND\n' "$path"
    exit 1
fi
printf 'Scanned files: 1\n'
SHIM
cat >"$TEST_DIR/bin/journalctl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${SECURITY_MODE:-high}" == high ]]; then lines=15; else lines=5; fi
for ((i = 0; i < lines; i++)); do printf 'Failed password from 192.0.2.10\n'; done
SHIM
cat >"$TEST_DIR/bin/ss" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${SECURITY_MODE:-high}" == high ]]; then lines=3; else lines=1; fi
for ((i = 0; i < lines; i++)); do printf 'SYN-RECV 0 0 192.0.2.1:443 192.0.2.10:50000\n'; done
SHIM
cat >"$TEST_DIR/bin/count-source" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "${SECURITY_MODE:-high}" in high) printf '12\n' ;; invalid_command) printf 'not-a-number\n' ;; *) printf '2\n' ;; esac
SHIM
cat >"$TEST_DIR/bin/capture-hook" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s %s\n' "$WATCHDOG_SERVICE" "$WATCHDOG_MATCH_COUNT" "$WATCHDOG_THRESHOLD" "$WATCHDOG_COMPARATOR" >>"$SECURITY_HOOK_LOG"
SHIM
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
export SECURITY_CLAM_ARGS="$TEST_DIR/clam-args"
export SECURITY_HOOK_LOG="$TEST_DIR/hooks"
export SECURITY_MODE=high
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}' "\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*" >"$TEST_DIR/uploads/test.txt"
for ((i = 0; i < 15; i++)); do printf '192.0.2.10 - - "GET / HTTP/1.1" 444 0\n'; done >"$TEST_DIR/access.log"

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
  default_attempts: 1
  default_retry_delay: 0
parallel:
  enabled: true
  max_jobs: 2
  temp_dir: "$TEST_DIR"
hooks:
  on_failure:
    - command: ["$TEST_DIR/bin/capture-hook"]
services:
  - name: upload-scan
    check:
      type: clamav
      path: "$TEST_DIR/uploads"
      recursive: true
      attempts: 1
  - name: ssh-bruteforce
    check:
      type: threshold
      source:
        type: journald
        unit: sshd
        since: "5 minutes ago"
        pattern: "Failed password"
      threshold: 10
      comparator: ">"
      attempts: 1
  - name: syn-flood
    check:
      type: threshold
      source:
        type: netstat
        state: SYN-RECV
      threshold: 2
      attempts: 1
  - name: nginx-flood
    check:
      type: threshold
      source:
        type: logfile
        path: "$TEST_DIR/access.log"
        pattern: " 444 "
        tail_lines: 100
      threshold: 10
      attempts: 1
  - name: custom-count
    check:
      type: threshold
      source:
        type: command
        command: ["$TEST_DIR/bin/count-source"]
      threshold: 10
      attempts: 1
YAML

bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" >"$TEST_DIR/validate.log" 2>&1 || { cat "$TEST_DIR/validate.log" >&2; fail 'valid config rejected'; }
set +e
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml"
status=$?
set -e
[[ "$status" == 1 ]] || fail 'threats did not return exit 1'
for service in upload-scan ssh-bruteforce syn-flood nginx-flood custom-count; do
    [[ "$(<"$TEST_DIR/state/$service.state")" == unavailable ]] || fail "$service not unavailable"
done
grep -q 'test.txt.*FOUND' "$TEST_DIR/watchdog.log" || fail 'EICAR filename missing from detail'
grep -q -- '-r' "$SECURITY_CLAM_ARGS" || fail 'recursive clamscan flag missing'
grep -q '^ssh-bruteforce 15 10 >$' "$SECURITY_HOOK_LOG" || fail 'parallel threshold variables missing from hook'

export SECURITY_MODE=low
printf 'clean file\n' >"$TEST_DIR/uploads/test.txt"
for ((i = 0; i < 5; i++)); do printf '192.0.2.10 - - "GET / HTTP/1.1" 444 0\n'; done >"$TEST_DIR/access.log"
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" || fail 'recovery run failed'
for service in upload-scan ssh-bruteforce syn-flood nginx-flood custom-count; do
    [[ "$(<"$TEST_DIR/state/$service.state")" == healthy ]] || fail "$service not healthy after recovery"
done

export SECURITY_MODE=scanner_error
set +e
bash "$ROOT_DIR/service-watchdog.sh" -s upload-scan -c "$TEST_DIR/config.yaml"
status=$?
set -e
[[ "$status" == 1 && "$(<"$TEST_DIR/state/upload-scan.state")" == unavailable ]] || fail 'scanner error was treated as healthy'
grep -q 'clamscan error:.*scanner failure' "$TEST_DIR/watchdog.log" || fail 'scanner error detail missing'

export SECURITY_MODE=invalid_command
set +e
bash "$ROOT_DIR/service-watchdog.sh" -s custom-count -c "$TEST_DIR/config.yaml"
status=$?
set -e
[[ "$status" == 1 && "$(<"$TEST_DIR/state/custom-count.state")" == unavailable ]] || fail 'invalid count was treated as healthy'
grep -q 'command source must output a non-negative integer' "$TEST_DIR/watchdog.log" || fail 'invalid count detail missing'

yq eval -i '.services[1].check.comparator = "danger"' "$TEST_DIR/config.yaml"
if bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" >"$TEST_DIR/invalid.log" 2>&1; then fail 'invalid comparator accepted'; fi
grep -q 'services\[1\].check.comparator' "$TEST_DIR/invalid.log" || fail 'invalid comparator error missing field path'

printf 'Security checks test passed.\n'
