#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { printf 'status test failed: %s\n' "$1" >&2; exit 1; }
json_value() { yq eval -p=json -o=json -r "$2" "$1"; }

mkdir -p "$TEST_DIR/state" "$TEST_DIR/bin" "$TEST_DIR/tmp"
WATCHDOG_REAL_DATE="$(command -v date)"
export WATCHDOG_REAL_DATE
cat >"$TEST_DIR/bin/date" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
    '+%a') printf 'Mon\n' ;;
    '+%H:%M') printf '12:00\n' ;;
    *) exec "$WATCHDOG_REAL_DATE" "$@" ;;
esac
SHIM
chmod +x "$TEST_DIR/bin/date"
export PATH="$TEST_DIR/bin:$PATH"
now="$(date '+%s')"

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/runtime/watchdog.log"
  lock_file: "$TEST_DIR/runtime/watchdog.lock"
  state_directory: "$TEST_DIR/state"
  default_action_cooldown: 300
templates:
  command_check:
    check:
      type: command
      commands:
        - command: [true]
services:
  - name: ok
    template: command_check
  - name: down
    template: command_check
    actions:
      cooldown: 300
    maintenance:
      windows:
        - name: deploy
          days: mon
          time: "11:00-13:00"
  - name: circuit
    template: command_check
    circuit_breaker:
      enabled: true
      failure_threshold: 2
      open_duration: 600
  - name: flap
    template: command_check
  - name: manual
    template: command_check
  - name: unknown
    template: command_check
YAML

printf 'healthy\n' >"$TEST_DIR/state/ok.state"
printf '%s\n' "$((now - 60))" >"$TEST_DIR/state/ok.last-transition"
printf '%s\n' "$((now - 5))" >"$TEST_DIR/state/ok.last-check"
printf 'unavailable\n' >"$TEST_DIR/state/down.state"
printf '%s\n' "$((now - 7200))" >"$TEST_DIR/state/down.last-transition"
printf '%s\n' "$((now - 60))" >"$TEST_DIR/state/down.last-check"
printf '%s\n' "$((now - 30))" >"$TEST_DIR/state/down.last-action"
printf '%s\n' "$((now + 600))" >"$TEST_DIR/state/down.backoff-next-attempt"
printf '2\n' >"$TEST_DIR/state/down.escalation-count"
printf '{"phase":"failed","state":"unavailable"}\n' >"$TEST_DIR/state/down.incident.json"
printf 'unavailable\n' >"$TEST_DIR/state/circuit.state"
printf 'open\n' >"$TEST_DIR/state/circuit.circuit-state"
printf 'degraded\n' >"$TEST_DIR/state/flap.state"
printf 'true\n' >"$TEST_DIR/state/flap.flapping-active"
printf 'unavailable\n' >"$TEST_DIR/state/manual.state"
printf 'true\n' >"$TEST_DIR/state/manual.manual-block"
printf 'healthy\n' >"$TEST_DIR/state/old.state"

export TMPDIR="$TEST_DIR/tmp"
find "$TEST_DIR/state" -type f -printf '%P %s %T@\n' | sort >"$TEST_DIR/before.snapshot"
status=0
bash "$ROOT_DIR/service-watchdog.sh" status -c "$TEST_DIR/config.yaml" \
    >"$TEST_DIR/table.out" 2>"$TEST_DIR/table.err" || status=$?
[[ "$status" == 1 ]] || fail "table exit should be 1, got ${status}"
grep -Fq 'SERVICE | STATE | PHASE | SINCE | LAST CHECK | NEXT ACTION | CIRCUIT | FLAPPING | MAINT | ESC' "$TEST_DIR/table.out" || fail 'table header missing'
grep -Fq 'down | unavailable | failed | ' "$TEST_DIR/table.out" || fail 'down row missing'
grep -Fq 'blocked: circuit-open' "$TEST_DIR/table.out" || fail 'circuit status missing'
grep -Fq 'blocked: flapping' "$TEST_DIR/table.out" || fail 'flapping status missing'
grep -Fq 'blocked: manual' "$TEST_DIR/table.out" || fail 'manual block missing'
grep -Fq ' | deploy | 2' "$TEST_DIR/table.out" || fail 'maintenance or escalation count missing'
grep -Fq 'unknown | unknown' "$TEST_DIR/table.out" || fail 'unknown service missing'
if grep -Fq '(orphaned)' "$TEST_DIR/table.out"; then fail 'orphan included without --all'; fi
if grep -q $'\033' "$TEST_DIR/table.out"; then fail 'ANSI color in redirected output'; fi

status=0
bash "$ROOT_DIR/service-watchdog.sh" status -c "$TEST_DIR/config.yaml" --json --all \
    >"$TEST_DIR/status.json" 2>"$TEST_DIR/json.err" || status=$?
[[ "$status" == 1 ]] || fail "JSON exit should be 1, got ${status}"
[[ "$(json_value "$TEST_DIR/status.json" 'length')" == 7 ]] || fail 'JSON service count wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "old") | .orphaned')" == true ]] || fail 'orphan flag missing'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .state')" == unavailable ]] || fail 'down state wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .phase')" == failed ]] || fail 'incident phase wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .maintenance')" == deploy ]] || fail 'maintenance missing'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .escalations')" == 2 ]] || fail 'escalation count wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "circuit") | .next_action')" == 'blocked: circuit-open' ]] || fail 'circuit block wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "flap") | .flapping')" == true ]] || fail 'flapping flag wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "manual") | .next_action')" == 'blocked: manual' ]] || fail 'manual block wrong'
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "unknown") | .state')" == unknown ]] || fail 'unknown state wrong'
remaining="$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .next_action_seconds')"
(( remaining > 500 && remaining <= 600 )) || fail "backoff remaining wrong: ${remaining}"
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .next_action')" == waiting ]] || fail 'waiting action kind wrong'
since="$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "down") | .since_seconds')"
(( since >= 7200 && since < 7300 )) || fail "since duration wrong: ${since}"
[[ "$(json_value "$TEST_DIR/status.json" '.[] | select(.service == "unknown") | .last_check')" == null ]] || fail 'unknown last check should be null'

bash "$ROOT_DIR/service-watchdog.sh" status -c "$TEST_DIR/config.yaml" -s ok --json >"$TEST_DIR/ok.json" || fail 'healthy-only status should exit 0'
[[ "$(json_value "$TEST_DIR/ok.json" 'length')" == 1 ]] || fail 'service filter failed'
bash "$ROOT_DIR/service-watchdog.sh" status -c "$TEST_DIR/config.yaml" -s old --all --json >"$TEST_DIR/old.json" || fail 'healthy orphan should exit 0'
[[ "$(json_value "$TEST_DIR/old.json" '.[0].orphaned')" == true ]] || fail 'orphan filter failed'

cp "$TEST_DIR/config.yaml" "$TEST_DIR/invalid.yaml"
yq eval -i '.services[1].check.type = "bogus"' "$TEST_DIR/invalid.yaml"
status=0
bash "$ROOT_DIR/service-watchdog.sh" status -c "$TEST_DIR/invalid.yaml" --json \
    >"$TEST_DIR/invalid.out" 2>"$TEST_DIR/invalid.err" || status=$?
[[ "$status" == 2 ]] || fail "invalid config should exit 2, got ${status}"
[[ ! -s "$TEST_DIR/invalid.out" ]] || fail 'invalid config produced partial JSON'

find "$TEST_DIR/state" -type f -printf '%P %s %T@\n' | sort >"$TEST_DIR/after.snapshot"
cmp -s "$TEST_DIR/before.snapshot" "$TEST_DIR/after.snapshot" || fail 'state files changed'
[[ ! -e "$TEST_DIR/runtime" ]] || fail 'log or lock directory was created'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1 -print -quit)" ]] || fail 'temporary file was created'

printf 'status command tests passed\n'
