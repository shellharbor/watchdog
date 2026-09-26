#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIRECTORY

cd "$PROJECT_DIRECTORY"

[[ "$(yq eval '.name' action.yml)" == 'Watchdog configuration validation' ]]
[[ "$(yq eval '.inputs.config.default' action.yml)" == config.yaml ]]
[[ "$(yq eval '.runs.using' action.yml)" == docker ]]
[[ "$(yq eval '.runs.image' action.yml)" == Dockerfile ]]
grep -F 'service-watchdog.sh validate -c' scripts/github-action-entrypoint.sh >/dev/null
grep -F 'GITHUB_WORKSPACE' scripts/github-action-entrypoint.sh >/dev/null

if [[ "${1:-}" == --docker ]]; then
    command -v docker >/dev/null 2>&1 || {
        printf '%s\n' 'Docker is required for the GitHub Action integration test.' >&2
        exit 2
    }
    action_image="watchdog-github-action-test-${BASHPID}"
    cleanup_action_image() {
        docker image rm --force "$action_image" >/dev/null 2>&1 || true
    }
    trap cleanup_action_image EXIT

    docker build --quiet --tag "$action_image" . >/dev/null
    docker run --rm \
        --env GITHUB_WORKSPACE=/workspace \
        --volume "${PROJECT_DIRECTORY}:/workspace:ro" \
        "$action_image" examples/dns-ping.yaml

    set +e
    docker run --rm \
        --env GITHUB_WORKSPACE=/workspace \
        --volume "${PROJECT_DIRECTORY}:/workspace:ro" \
        "$action_image" tests/fixtures/invalid/dns-record-type.yaml >/dev/null 2>&1
    invalid_status=$?
    set -e
    [[ "$invalid_status" == 2 ]] || {
        printf 'GitHub Action returned %s for an invalid configuration; expected 2.\n' "$invalid_status" >&2
        exit 1
    }

    set +e
    docker run --rm \
        --env GITHUB_WORKSPACE=/workspace \
        --volume "${PROJECT_DIRECTORY}:/workspace:ro" \
        "$action_image" /etc/passwd >/dev/null 2>&1
    outside_workspace_status=$?
    set -e
    [[ "$outside_workspace_status" == 2 ]] || {
        printf 'GitHub Action accepted a configuration outside the workspace.\n' >&2
        exit 1
    }
fi

printf '%s\n' 'GitHub Action test passed.'
