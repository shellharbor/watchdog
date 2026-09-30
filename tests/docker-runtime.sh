#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIRECTORY
readonly RUNTIME_DOCKERFILE="${PROJECT_DIRECTORY}/packaging/docker/Dockerfile"
readonly RUNTIME_ENTRYPOINT="${PROJECT_DIRECTORY}/packaging/docker/entrypoint.sh"
readonly COMPOSE_EXAMPLE="${PROJECT_DIRECTORY}/docker-compose.example.yml"
readonly PUBLISH_WORKFLOW="${PROJECT_DIRECTORY}/.github/workflows/docker-publish.yml"

fail() {
    printf 'Docker runtime test failure: %s\n' "$*" >&2
    exit 1
}

[[ -f "$RUNTIME_DOCKERFILE" ]] || fail 'missing production runtime Dockerfile'
[[ -f "$RUNTIME_ENTRYPOINT" ]] || fail 'missing container entrypoint'
[[ -f "$COMPOSE_EXAMPLE" ]] || fail 'missing Compose example'
[[ -f "$PUBLISH_WORKFLOW" ]] || fail 'missing container publication workflow'
grep -F 'USER 10001:10001' "$RUNTIME_DOCKERFILE" >/dev/null
grep -F 'HEALTHCHECK' "$RUNTIME_DOCKERFILE" >/dev/null
grep -F "validate -c \"\$config_path\"" "$RUNTIME_ENTRYPOINT" >/dev/null
grep -F 'profiles: [docker-actions]' "$COMPOSE_EXAMPLE" >/dev/null
grep -F '/var/run/docker.sock:/var/run/docker.sock' "$COMPOSE_EXAMPLE" >/dev/null
grep -F 'cap_drop:' "$COMPOSE_EXAMPLE" >/dev/null
grep -F 'no-new-privileges:true' "$COMPOSE_EXAMPLE" >/dev/null
grep -F 'linux/amd64,linux/arm64' "$PUBLISH_WORKFLOW" >/dev/null
grep -F 'provenance: mode=max' "$PUBLISH_WORKFLOW" >/dev/null
grep -F 'sbom: true' "$PUBLISH_WORKFLOW" >/dev/null
grep -F 'DOCKERHUB_TOKEN' "$PUBLISH_WORKFLOW" >/dev/null
grep -F 'cancel-in-progress: false' "$PUBLISH_WORKFLOW" >/dev/null

if grep -Eq 'privileged:[[:space:]]*true|network_mode:[[:space:]]*host' "$COMPOSE_EXAMPLE"; then
    fail 'Compose example must not grant privileged mode or host networking'
fi

if [[ "${1:-}" == "" ]]; then
    printf '%s\n' 'Docker runtime static test passed.'
    exit 0
fi

case "$1" in
    --docker|--docker-socket) ;;
    *) fail "unknown option: $1" ;;
esac

command -v docker >/dev/null 2>&1 || {
    printf '%s\n' 'Docker is required for the container integration test.' >&2
    exit 2
}
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || {
    printf '%s\n' 'A reachable Docker daemon is required for the container integration test.' >&2
    exit 2
}
docker compose -f "$COMPOSE_EXAMPLE" config >/dev/null

runtime_image="watchdog-runtime-test-${BASHPID}"
docker_image="watchdog-runtime-docker-test-${BASHPID}"
test_directory="$(mktemp -d)"
runtime_container="watchdog-runtime-cycle-${BASHPID}"
health_container="watchdog-runtime-health-${BASHPID}"

assert_persisted_runtime_state() {
    docker run --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --user 10001:10001 \
        --volume "${test_directory}/state:/var/lib/watchdog:ro" \
        --entrypoint test \
        "$runtime_image" -f /var/lib/watchdog/state/container-runtime.state
}

cleanup() {
    docker rm --force "$runtime_container" "$health_container" >/dev/null 2>&1 || true
    # The runtime deliberately changes its state directory to mode 0750. Give
    # the host-side temporary test directory back to its creator before cleanup
    # without weakening the production image's restrictive state permissions.
    if [[ -d "${test_directory}/state" ]]; then
        docker run --rm \
            --network none \
            --cap-drop ALL \
            --cap-add DAC_OVERRIDE \
            --cap-add FOWNER \
            --security-opt no-new-privileges \
            --user 0:0 \
            --volume "${test_directory}/state:/state" \
            --entrypoint chmod \
            "$runtime_image" -R a+rwx /state >/dev/null 2>&1 || true
    fi
    rm -rf -- "$test_directory"
    docker image rm --force "$runtime_image" "$docker_image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build --quiet --file "$RUNTIME_DOCKERFILE" --target runtime --tag "$runtime_image" "$PROJECT_DIRECTORY" >/dev/null
docker build --quiet --file "$RUNTIME_DOCKERFILE" --target docker --tag "$docker_image" "$PROJECT_DIRECTORY" >/dev/null

[[ "$(docker image inspect --format '{{.Config.User}}' "$runtime_image")" == '10001:10001' ]] || fail 'runtime image must default to the non-root user'
docker run --rm --entrypoint docker "$docker_image" --version >/dev/null

if [[ "$1" == --docker-socket ]]; then
    if [[ ! -S /var/run/docker.sock ]]; then
        printf '%s\n' 'Docker socket integration skipped: no host socket is available.'
        exit 0
    fi
    socket_group="$(stat -c '%g' /var/run/docker.sock)"
    docker run --rm \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --group-add "$socket_group" \
        --volume /var/run/docker.sock:/var/run/docker.sock \
        --entrypoint docker \
        "$docker_image" version --format '{{.Server.Version}}' >/dev/null
    printf '%s\n' 'Docker socket integration test passed.'
    exit 0
fi

mkdir -p "${test_directory}/state"
chmod 0777 "${test_directory}/state"

cat >"${test_directory}/config.yaml" <<'YAML'
settings:
  log_file: /var/lib/watchdog/watchdog.log
  lock_file: /tmp/watchdog.lock
  state_directory: /var/lib/watchdog/state
  default_timeout: 5
  default_attempts: 1
  default_retry_delay: 0

services:
  - name: container-runtime
    check:
      type: command
      commands:
        - command: [test, "!", -S, /var/run/docker.sock]
YAML

cat >"${test_directory}/invalid.yaml" <<'YAML'
settings:
  log_file: /var/lib/watchdog/watchdog.log
  lock_file: /tmp/watchdog.lock
  state_directory: /var/lib/watchdog/state
services: []
YAML

cat >"${test_directory}/slow.yaml" <<'YAML'
settings:
  log_file: /var/lib/watchdog/watchdog.log
  lock_file: /tmp/watchdog.lock
  state_directory: /var/lib/watchdog/state
  default_timeout: 60
  default_attempts: 1
  default_retry_delay: 0

services:
  - name: slow-container-runtime
    check:
      type: command
      commands:
        - command: [sleep, "30"]
YAML

runtime_flags=(
    --read-only
    --tmpfs '/tmp:rw,noexec,nosuid,size=64m'
    --cap-drop ALL
    --security-opt no-new-privileges
    --user 10001:10001
    --volume "${test_directory}/state:/var/lib/watchdog"
)

docker run --detach --name "$runtime_container" \
    "${runtime_flags[@]}" \
    --volume "${test_directory}/config.yaml:/etc/watchdog/config.yaml:ro" \
    "$runtime_image" >/dev/null

runtime_exit="$(docker wait "$runtime_container")"
if [[ "$runtime_exit" != 0 ]]; then
    docker logs "$runtime_container" >&2 || true
    fail "representative healthy cycle exited ${runtime_exit}, expected 0"
fi
assert_persisted_runtime_state || fail 'healthy cycle did not persist state to the mounted volume'
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$runtime_container")" == true ]] || fail 'runtime cycle was not read-only'
[[ "$(docker inspect --format '{{.HostConfig.Privileged}}' "$runtime_container")" == false ]] || fail 'runtime cycle was privileged'
if docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$runtime_container" | grep -Fx '/var/run/docker.sock' >/dev/null; then
    fail 'default runtime cycle mounted the Docker socket'
fi

set +e
docker run --rm \
    "${runtime_flags[@]}" \
    --volume "${test_directory}/invalid.yaml:/etc/watchdog/config.yaml:ro" \
    "$runtime_image" validate >/dev/null 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" == 2 ]] || fail "invalid configuration returned ${invalid_status}, expected 2"

docker run --detach --name "$health_container" \
    "${runtime_flags[@]}" \
    --volume "${test_directory}/slow.yaml:/etc/watchdog/config.yaml:ro" \
    "$runtime_image" >/dev/null

health_status=''
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    health_status="$(docker inspect --format '{{.State.Health.Status}}' "$health_container")"
    [[ "$health_status" == healthy ]] && break
    [[ "$health_status" != unhealthy ]] || fail 'container healthcheck reported unhealthy for a valid configuration'
    sleep 1
done
[[ "$health_status" == healthy ]] || fail 'container healthcheck did not become healthy'

docker stop --time 2 "$health_container" >/dev/null
[[ "$(docker wait "$health_container")" == 2 ]] || fail 'SIGTERM did not preserve Watchdog runtime exit code 2'

printf '%s\n' 'Docker runtime integration test passed.'
