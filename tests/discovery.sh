#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() { printf 'discovery test failed: %s\n' "$1" >&2; exit 1; }
assert_yaml() {
    local file="$1" expression="$2" expected="$3" actual
    actual="$(yq eval -r "$expression" "$file")"
    [[ "$actual" == "$expected" ]] || fail "${expression}: expected ${expected}, got ${actual}"
}
expect_failure() {
    local label="$1" reason="$2" status=0
    shift 2
    bash "$ROOT_DIR/watchdog-discover.sh" "$@" >"$TEST_DIR/failure.out" 2>"$TEST_DIR/failure.log" || status=$?
    (( status == 2 )) || fail "${label}: expected exit 2, got ${status}"
    grep -Fq "reason=${reason}" "$TEST_DIR/failure.log" || fail "${label}: missing ${reason} diagnostic"
}

mkdir -p -- "$TEST_DIR/project" "$TEST_DIR/output" "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker was executed\n' >>"$DISCOVERY_MARKER"
exit 97
STUB
cat >"$TEST_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl was executed\n' >>"$DISCOVERY_MARKER"
exit 97
STUB
chmod +x "$TEST_DIR/bin/docker" "$TEST_DIR/bin/systemctl"
export DISCOVERY_MARKER="$TEST_DIR/executed"
export PATH="$TEST_DIR/bin:$PATH"
cat >"$TEST_DIR/project/compose.yml" <<'YAML'
services:
  web:
    image: nginx:alpine
    ports: ["8080:80"]
    healthcheck:
      test: [CMD, wget, -q, --spider, "http://localhost/"]
  db:
    image: postgres:16
    ports:
      - target: 5432
        published: 5432
        protocol: tcp
  ignored:
    image: nginx:alpine
    ports: ["3000:3000"]
    labels:
      watchdog.ignore: "true"
  exposed-only:
    image: alpine
    expose: ["9999"]
  udp-only:
    image: alpine
    ports: ["5353:53/udp"]
  remote-bind:
    image: nginx:alpine
    ports: ["192.0.2.10:8080:80"]
YAML
cat >"$TEST_DIR/app.service" <<'UNIT'
[Unit]
Description=Test application
[Service]
Type=notify
ExecStart=/usr/bin/app --port 3000
UNIT
cat >"$TEST_DIR/backup.service" <<'UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
UNIT
cat >"$TEST_DIR/config.yaml" <<YAML
discovery:
  enabled: true
  output_dir: "$TEST_DIR/output"
  output_prefix: "auto-"
  docker_compose:
    enabled: true
    sources: ["$TEST_DIR/project"]
    skip_labels: ["watchdog.ignore=true"]
    http_ports: [8080, 3000]
    default_actions:
      cooldown: 300
      verify_after: 10
      commands:
        - command: [docker, compose, restart, "{{service_name}}"]
          working_directory: "{{compose_dir}}"
          timeout: 120
  systemd:
    enabled: true
    sources: ["$TEST_DIR/app.service", "$TEST_DIR/backup.service"]
    only_service_types: [simple, notify, forking]
    detect_ports: true
    default_actions:
      commands:
        - command: [systemctl, restart, "{{unit_name}}"]
          timeout: 60
YAML

bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/config.yaml" --source docker --dry-run \
    >"$TEST_DIR/docker.yaml" 2>"$TEST_DIR/docker.log"
[[ ! -e "$TEST_DIR/output/auto-discovery.yaml" ]] || fail 'dry-run wrote output'
assert_yaml "$TEST_DIR/docker.yaml" '.services | length' '2'
assert_yaml "$TEST_DIR/docker.yaml" '.services[] | select(.name == "project-web") | .check.type' 'http'
assert_yaml "$TEST_DIR/docker.yaml" '.services[] | select(.name == "project-web") | .check.url' 'http://localhost:8080'
assert_yaml "$TEST_DIR/docker.yaml" '.services[] | select(.name == "project-db") | .check.type' 'tcp'
assert_yaml "$TEST_DIR/docker.yaml" '.services[] | select(.name == "project-db") | .check.port' '5432'
assert_yaml "$TEST_DIR/docker.yaml" '.services[] | select(.name == "project-web") | .actions.commands[0].command[3]' 'web'
assert_yaml "$TEST_DIR/docker.yaml" '.services[] | select(.name == "project-web") | .actions.commands[0].working_directory' "$TEST_DIR/project"
grep -q 'reason=skip_label' "$TEST_DIR/docker.log" || fail 'missing skip-label diagnostic'
grep -q 'reason=no_published_tcp_port' "$TEST_DIR/docker.log" || fail 'missing unusable-port diagnostic'

bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/config.yaml" --source systemd --dry-run \
    >"$TEST_DIR/systemd.yaml" 2>"$TEST_DIR/systemd.log"
assert_yaml "$TEST_DIR/systemd.yaml" '.services | length' '1'
assert_yaml "$TEST_DIR/systemd.yaml" '.services[0].check.type' 'http'
assert_yaml "$TEST_DIR/systemd.yaml" '.services[0].check.url' 'http://localhost:3000'
assert_yaml "$TEST_DIR/systemd.yaml" '.services[0].actions.commands[0].command[2]' 'app.service'
grep -q 'reason=type_oneshot' "$TEST_DIR/systemd.log" || fail 'missing type-filter diagnostic'

bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/config.yaml" >/dev/null 2>"$TEST_DIR/write.log"
target="$TEST_DIR/output/auto-discovery.yaml"
[[ -f "$target" ]] || fail 'output file missing'
assert_yaml "$target" '.services | length' '3'
cat >"$TEST_DIR/base.yaml" <<YAML
settings:
  log_file: "$TEST_DIR/watchdog.log"
  lock_file: "$TEST_DIR/watchdog.lock"
  state_directory: "$TEST_DIR/state"
YAML
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$TEST_DIR/base.yaml" "$target" >"$TEST_DIR/merged.yaml"
bash "$ROOT_DIR/service-watchdog.sh" validate -c "$TEST_DIR/merged.yaml" \
    >"$TEST_DIR/validate.log" 2>&1 || fail 'generated services failed watchdog validation'
printf 'sentinel\n' >"$target"
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/config.yaml" >/dev/null 2>"$TEST_DIR/existing.log"
[[ "$(<"$target")" == sentinel ]] || fail 'existing file overwritten without --force'
grep -q 'reason=file_exists' "$TEST_DIR/existing.log" || fail 'missing existing-file diagnostic'
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/config.yaml" --force >/dev/null 2>"$TEST_DIR/force.log"
assert_yaml "$target" '.services | length' '3'

yq eval -i '.discovery.docker_compose.only_with_healthcheck = true' "$TEST_DIR/config.yaml"
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/config.yaml" --source docker --format stdout \
    >"$TEST_DIR/filtered.yaml" 2>"$TEST_DIR/filtered.log"
assert_yaml "$TEST_DIR/filtered.yaml" '.services | length' '1'
assert_yaml "$target" '.services | length' '3'
grep -q 'reason=no_healthcheck' "$TEST_DIR/filtered.log" || fail 'missing healthcheck-filter diagnostic'

cp -- "$TEST_DIR/config.yaml" "$TEST_DIR/variant.yaml"
yq eval -i '.discovery.systemd.detect_ports = false' "$TEST_DIR/variant.yaml"
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/variant.yaml" --source systemd --dry-run \
    >"$TEST_DIR/fallback.yaml" 2>"$TEST_DIR/fallback.log"
assert_yaml "$TEST_DIR/fallback.yaml" '.services[0].check.type' 'command'
assert_yaml "$TEST_DIR/fallback.yaml" '.services[0].check.commands[0].command[3]' 'app.service'

mkdir -p -- "$TEST_DIR/units"
cp -- "$TEST_DIR/app.service" "$TEST_DIR/units/app.service"
cat >"$TEST_DIR/units/worker.service" <<'UNIT'
[Service]
Type=simple
ExecStart=/usr/bin/worker
UNIT
cp -- "$TEST_DIR/config.yaml" "$TEST_DIR/variant.yaml"
export UNIT_GLOB="$TEST_DIR/units/*.service"
yq eval -i '.discovery.systemd.sources = [strenv(UNIT_GLOB)]' "$TEST_DIR/variant.yaml"
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/variant.yaml" --source systemd --dry-run \
    >"$TEST_DIR/glob.yaml" 2>"$TEST_DIR/glob.log"
assert_yaml "$TEST_DIR/glob.yaml" '.services | length' '2'
assert_yaml "$TEST_DIR/glob.yaml" '.services[] | select(.name == "worker") | .check.type' 'command'
assert_yaml "$TEST_DIR/glob.yaml" '.services[] | select(.name == "worker") | .check.commands[0].command[3]' 'worker.service'
yq eval -i '.discovery.systemd.skip_patterns = ["worker"]' "$TEST_DIR/variant.yaml"
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/variant.yaml" --source systemd --dry-run \
    >"$TEST_DIR/glob-filtered.yaml" 2>"$TEST_DIR/glob-filtered.log"
assert_yaml "$TEST_DIR/glob-filtered.yaml" '.services | length' '1'
grep -q 'reason=skip_pattern' "$TEST_DIR/glob-filtered.log" || fail 'missing systemd skip-pattern diagnostic'

cp -- "$TEST_DIR/config.yaml" "$TEST_DIR/variant.yaml"
export MISSING_SOURCE="$TEST_DIR/missing/compose.yml"
yq eval -i '.discovery.docker_compose.sources = [strenv(MISSING_SOURCE)]' "$TEST_DIR/variant.yaml"
bash "$ROOT_DIR/watchdog-discover.sh" -c "$TEST_DIR/variant.yaml" --source docker --dry-run \
    >"$TEST_DIR/empty.yaml" 2>"$TEST_DIR/empty.log"
assert_yaml "$TEST_DIR/empty.yaml" '.services | length' '0'
grep -q 'reason=source_not_found' "$TEST_DIR/empty.log" || fail 'missing source warning'

cp -- "$TEST_DIR/config.yaml" "$TEST_DIR/invalid.yaml"
yq eval -i '.discovery.enabled = "true"' "$TEST_DIR/invalid.yaml"
expect_failure 'string enabled' 'discovery.enabled_must_be_boolean' -c "$TEST_DIR/invalid.yaml" --dry-run
cp -- "$TEST_DIR/config.yaml" "$TEST_DIR/invalid.yaml"
yq eval -i '.discovery.output_dir = "relative/path"' "$TEST_DIR/invalid.yaml"
expect_failure 'relative output' 'discovery.output_dir_must_be_absolute' -c "$TEST_DIR/invalid.yaml" --dry-run
cp -- "$TEST_DIR/config.yaml" "$TEST_DIR/invalid.yaml"
yq eval -i '.discovery.docker_compose.sources = {"bad": "path"}' "$TEST_DIR/invalid.yaml"
expect_failure 'non-array sources' 'discovery.docker_compose.sources_must_be_array' -c "$TEST_DIR/invalid.yaml" --dry-run
expect_failure 'invalid source flag' 'source_must_be_docker_or_systemd' -c "$TEST_DIR/config.yaml" --source unknown

(cd "$ROOT_DIR" && bash ./watchdog-discover.sh -c examples/auto-discovery/discovery.yaml --dry-run) \
    >"$TEST_DIR/example.yaml" 2>"$TEST_DIR/example.log"
yq eval -o=json '.' "$TEST_DIR/example.yaml" >"$TEST_DIR/example.json"
yq eval -o=json '.' "$ROOT_DIR/examples/auto-discovery/generated-watchdog.yaml" >"$TEST_DIR/expected-example.json"
cmp -s "$TEST_DIR/example.json" "$TEST_DIR/expected-example.json" || fail 'documented example differs from generated output'

[[ ! -e "$DISCOVERY_MARKER" ]] || fail 'discovery executed Docker or systemctl'

printf 'discovery tests passed\n'
