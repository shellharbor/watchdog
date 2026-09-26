#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { printf 'history test failed: %s\n' "$1" >&2; exit 1; }

cat >"$TEST_DIR/config.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
  default_attempts: 1
  default_retry_delay: 0
history:
  enabled: true
  storage: jsonl
  path: "$TEST_DIR/history"
  rotation:
    mode: daily
    max_age_days: 30
  reports:
    trend_dots: 2
services:
  - name: api
    check:
      type: command
      commands:
        - command: [/bin/true]
YAML

bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" >"$TEST_DIR/validate.log" 2>&1 || { cat "$TEST_DIR/validate.log" >&2; fail 'valid history config rejected'; }
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" || fail 'healthy check failed'
daily_file="$TEST_DIR/history/history_$(date '+%Y-%m-%d').jsonl"
[[ -f "$daily_file" ]] || fail 'daily history file missing'
[[ "$(wc -l <"$daily_file")" == 1 ]] || fail 'expected one history row'
python3 - "$daily_file" <<'PY'
import json
import pathlib
import sys
row = json.loads(pathlib.Path(sys.argv[1]).read_text().strip())
assert row['service'] == 'api' and row['state'] == 'healthy'
assert row['check_type'] == 'command' and isinstance(row['duration_sec'], int)
assert row['node_id'] and row['timestamp']
PY

before="$(find "$TEST_DIR" -type f -printf '%p %s %T@\n' | sort)"
report="$(bash "$ROOT_DIR/service-watchdog.sh" --report daily --config "$TEST_DIR/config.yaml")" || fail 'daily report failed'
[[ "$report" == *'api'* && "$report" == *'100.0%'* ]] || fail 'report missing api uptime'
trend="$(bash "$ROOT_DIR/service-watchdog.sh" --trend api -c "$TEST_DIR/config.yaml")" || fail 'trend failed'
[[ "$trend" == *'█'* && "$trend" == *'MTTR:'* ]] || fail 'trend missing timeline or statistics'
after="$(find "$TEST_DIR" -type f -printf '%p %s %T@\n' | sort)"
[[ "$before" == "$after" ]] || fail 'report or trend modified files'

bash "$ROOT_DIR/service-watchdog.sh" -n -c "$TEST_DIR/config.yaml" || fail 'dry run failed'
[[ "$(wc -l <"$daily_file")" == 1 ]] || fail 'dry run wrote history'

first="$(date -Iseconds -d '60 seconds ago')"
second="$(date -Iseconds -d '30 seconds ago')"
third="$(date -Iseconds)"
printf '{"timestamp":"%s","service":"api","state":"healthy"}\n' "$first" >"$daily_file"
printf '{"timestamp":"%s","service":"api","state":"unavailable"}\n' "$second" >>"$daily_file"
printf '{"timestamp":"%s","service":"api","state":"healthy"}\n' "$third" >>"$daily_file"
yq eval -i '.history.reports.trend_dots = 3' "$TEST_DIR/config.yaml"
report="$(bash "$ROOT_DIR/service-watchdog.sh" --report weekly -c "$TEST_DIR/config.yaml")" || fail 'weekly report failed'
[[ "$report" == *'66.7%'* && "$report" == *'30s'* ]] || fail 'weekly outage statistics wrong'
trend="$(bash "$ROOT_DIR/service-watchdog.sh" --trend api -c "$TEST_DIR/config.yaml")" || fail 'outage trend failed'
[[ "$trend" == *'█░█'* && "$trend" == *'Falls: 1'* && "$trend" == *'MTTR: 30s'* ]] || fail 'trend recovery statistics wrong'
old_file="$TEST_DIR/history/history_2020-01-01.jsonl"
printf '{"timestamp":"2020-01-01T00:00:00+00:00","service":"api","state":"healthy"}\n' >"$old_file"
touch -d '40 days ago' "$old_file"
bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" || fail 'daily rotation run failed'
[[ ! -e "$old_file" ]] || fail 'old daily history file not deleted'

yq eval -i '.history.rotation.mode = "single" | .history.rotation.max_records = 2' "$TEST_DIR/config.yaml"
for _ in 1 2 3; do bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" || fail 'single-mode check failed'; done
[[ "$(wc -l <"$TEST_DIR/history/history.jsonl")" == 2 ]] || fail 'single-mode max_records not enforced'

yq eval -i '.history.storage = "invalid"' "$TEST_DIR/config.yaml"
if bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/config.yaml" >"$TEST_DIR/error" 2>&1; then fail 'invalid storage accepted'; fi
grep -q 'history.storage' "$TEST_DIR/error" || fail 'invalid storage error missing field path'

if command -v sqlite3 >/dev/null 2>&1; then
    export TEST_DIR
    yq eval -i '.history.storage = "sqlite" | .history.path = strenv(TEST_DIR) + "/history.db"' "$TEST_DIR/config.yaml"
    bash "$ROOT_DIR/service-watchdog.sh" -c "$TEST_DIR/config.yaml" || fail 'SQLite check failed'
    [[ "$(sqlite3 "$TEST_DIR/history.db" 'SELECT COUNT(*) FROM checks;')" == 1 ]] || fail 'SQLite row missing'
fi

printf 'History test passed.\n'
