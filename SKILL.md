---
name: watchdog-bash-monitor
description: Extend or maintain ShellHarbor Watchdog's one-shot Bash monitor when changing checks, YAML configuration, notifications, state, history, CLI commands, or parallel execution.
---

# Watchdog Bash Monitor

Use this repository-wide guide for implementation, debugging, and review inside
this repository. It is not a general Bash skill and does not apply to unrelated
projects.

## Operating contract

- The main entrypoint is the generated `service-watchdog.sh`; it is a Linux
  Bash 4.3+ one-shot monitor. Edit its ordered source modules in
  `lib/watchdog/`, regenerate it with `scripts/build-watchdog.sh`, and verify
  it with `scripts/build-watchdog.sh --check`. The released/installed script
  remains self-contained and never sources modules at runtime.
  `watchdog-discover.sh` is a separate offline generator.
- Preserve exit codes: `0` healthy/no remediation, `1` unavailable or a
  remediation attempt, and `2` configuration or runtime error.
- Keep new behavior opt-in. Do not change existing state-file names or format,
  metric names, defaults, or established configuration semantics unless the
  task explicitly requires it.
- Configured commands are argv arrays and run directly: never add `eval` or a
  configured `bash -c`. Secrets belong only in `*_env` fields and must never
  reach logs, state, metrics, examples, history, or status pages.
- Transition semantics are central: failure/recovery notifications, hooks, and
  remediation must not be duplicated for a continuing failure.
- An HTTP `expect.max_total_ms` breach is a `degraded` latency signal: preserve
  its transition alert and metrics, but never route it into remediation,
  circuit-breaker, backoff, flapping, or unavailable-counter handling.
- HTTP `expect.json` assertions are deliberately constrained: accept only `$`,
  `.field`, and zero-based `[index]` path segments; at most 20 assertions; and
  exactly one typed scalar `equals` or string-only ERE `regex` per assertion.
  Parse the existing 64 KiB private response capture as JSON, fail missing or
  null paths, and never include a response body or asserted value in details.
- HTTP `tls` and `proxy` maps are opt-in transport configuration for ordinary
  HTTP and liveness/readiness checks. Preserve default curl verification; use
  absolute readable PEM files, require client certificate/key pairs, and reject
  proxy URLs with embedded credentials. Do not add encrypted-key passphrase
  support that could expose a secret in argv. Proxy username/password must be paired
  `*_env` fields and must reach curl only through a private mode-`0600` config
  file—never argv, logs, state, history, metrics, or status-page output.
- `tls_cert` is an optional OpenSSL-backed leaf-certificate expiry check. It
  must verify `openssl` only when enabled, pass host and SNI as separate argv
  values, and expose expiry context without logging or persisting certificate
  contents.
- `dns` and `ping` are optional network checks backed by `dig` and Linux
  `ping`, respectively. Validate those tools only for services that select the
  corresponding type; preserve exact DNS answer matching and bounded ICMP loss
  and RTT semantics.
- PagerDuty and Opsgenie are on-call notification channels. They must use the
  Watchdog incident ID as their deduplication key/alias, trigger on failure or
  escalation, resolve only on recovery, and keep credentials and JSON payloads
  out of logs and curl argv.
- `services[].notify` can narrow delivery to already globally enabled channels
  and attach severity/runbook context. Omitting `channels` must preserve
  all-enabled-channel delivery; severity maps directly to PagerDuty and to the
  documented Opsgenie priority, and runbook URLs must remain non-secret.
- `actions.http` is first-class remote remediation, not a shell escape hatch.
  It shares all ordinary remediation guards and in enforce mode must match an
  exact `security.remediation_policy.allowed_http` method/URL entry. Header and
  body secrets use `*_env` and private temporary files.
- `action.yml` is the public Docker Action for CI configuration validation. It
  must invoke only `validate`, keep its config path inside `GITHUB_WORKSPACE`,
  and exit with Watchdog's normal validation status. Keep its image dependencies
  sufficient for every optional check type and cover its valid and invalid
  behavior through `tests/github-action.sh --docker` in CI.
- `packaging/docker/Dockerfile` is the production one-shot container image;
  it is intentionally separate from the root Dockerfile used by `action.yml`.
  Preserve its non-root UID/GID `10001`, default least-privilege contract, and
  `WATCHDOG_CONFIG` mount interface. The image healthcheck runs only
  `validate`, never target checks; target health remains the scheduled run's
  exit status. Its entrypoint must forward stop signals through Watchdog's
  check process tree, wait for cleanup, and retain Watchdog's exit code. Docker
  daemon access belongs only in the explicit `-docker` image/profile and must
  never become a default mount, capability, privilege, or network setting.
- Every new Dockerfile, Compose service, and microservice container contract
  must stay Kubernetes-ready: one explicit non-root workload with graceful
  signal handling; configuration and secrets through environment variables or
  read-only mounts; only declared persistent storage; portable DNS/URLs; and
  explicit health/readiness behavior. Never depend on fixed container names,
  Compose `depends_on`, host networking or paths, privileged mode, or the
  Docker socket by default. Kubernetes manifests, Helm charts, and an
  orchestrator dependency are not implied unless the user requests them.
- Kubernetes deployment is a Helm 3 chart under `charts/watchdog/`, not a
  controller or a Deployment: Watchdog runs as a finite `CronJob` and optional
  manual `Job`, and its `0`/`1`/`2` exit status is the health signal. Preserve
  the suspended-by-default schedule, `Forbid` concurrency policy, persistent
  transition state, ConfigMap-only configuration, existing-Secret `*_env`
  injection, and non-root pod contract. The chart must never gain RBAC,
  service-account token mounting, host paths/networking, privileged access, a
  Docker socket, or a Docker CLI profile. Keep `tests/kubernetes_chart.py` and
  `tests/kubernetes_integration.py` aligned with the chart and run them through
  the isolated kind workflow; the latter must never address a user kubeconfig
  or cluster.
- `status_page.uptime` is opt-in and requires `history.enabled: true`. It
  renders only sampled, observed availability from history: preserve grey
  intervals when no record exists and never present the bars as an SLA.
- `metrics.heartbeat.enabled` is opt-in scheduler liveness, not a service
  health signal. Emit `<prefix>_heartbeat_timestamp_seconds` only after a
  complete normal run and only with configured static labels; an unavailable
  service still refreshes it. Never refresh it for dry runs, read-only
  commands, configuration/runtime failures, or manual `-s` partial runs.
  Retain the last full-run timestamp atomically so a partial metrics rewrite
  exports the old timestamp rather than removing or refreshing the series.
  Keep the Grafana dashboard and Prometheus/Alertmanager assets under
  `observability/` synchronized with exported metric names and labels.
- `--dry-run` may perform checks but must not persist state/history/metrics or
  send notifications, run actions, or run hooks. `validate`, `status`,
  `--report`, and `--trend` must not run checks. `status`, reports, and trends
  are read-only and do not acquire the watchdog lock.

## Change routing

For a new or changed check type, trace the full path:

1. Add boundary validation in `validate_check_definition` (and a focused
   helper when needed). Missing optional external tools must fail only when the
   corresponding feature is enabled.
2. Add runtime behavior near the existing `check_*` helpers and dispatch it in
   `perform_single_check`.
3. Preserve the parallel-check seam: workers write result fields through
   `write_parallel_result`, `collect_check_results` restores them, and
   `use_preloaded_check_result` makes them visible to state transitions,
   templates, hooks, and history. Workers must close inherited lock fd `9`.
4. If a value reaches email/webhooks/hooks/history, add the same safe handling
   to the relevant rendering or serialization path. Sanitize details and never
   serialize secrets.
5. Update `schema/watchdog.schema.json`, `config.example.yaml`, an appropriate
   `examples/*.yaml` file, `examples/README.md`, `README.md`, `wiki/`,
   `CHANGELOG.md`, and CI only when the public behavior or test inventory
   changes. Keep Wiki navigation in `wiki/_Sidebar.md` synchronized when pages
   are added, renamed, or removed.

Use `security.remediation_policy` rules for remediation and escalation actions.
Check commands and hooks are administrator-trusted configuration, but still
must use argv arrays and bounded timeouts.

## Persistence and concurrency

- State and incident files use temporary files followed by `mv`; retain that
  atomic update pattern. History JSONL is the deliberate exception: a lock-held
  normal run appends snapshots after completed checks.
- Parallelism applies only to checks. State updates, notifications, actions,
  hooks, history writes, metrics, and status-page generation remain sequential.
- History records only completed checks, never dry runs or services skipped by
  a condition, maintenance handling, or dependency failure.

## Verification

Start with the narrowest changed test in `tests/`, then run the relevant
configuration/schema test and broader regression coverage:

```bash
bash ./scripts/build-watchdog.sh --check
bash ./scripts/release-preflight.sh vX.Y.Z # before creating a release tag
bash -n service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh scripts/release-preflight.sh lib/watchdog/*.sh tests/*.sh
bash -n scripts/github-action-entrypoint.sh packaging/docker/*.sh
shellcheck service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh scripts/release-preflight.sh scripts/github-action-entrypoint.sh packaging/docker/*.sh tests/*.sh
bash ./tests/versioning.sh
bash ./tests/run-all.sh
bash ./tests/docker-runtime.sh --docker
bash ./tests/docker-runtime.sh --docker-socket
helm lint charts/watchdog --strict
python3 ./tests/kubernetes_chart.py
python3 ./tests/kubernetes_integration.py
```

Before creating a release tag, run `scripts/release-preflight.sh` with that
exact tag. It is the same check used by the release workflow and the versioning
test, so `VERSION`, generated CLI output, README archive instructions,
changelog, and installer metadata cannot silently drift apart.

`tests/run-all.sh` is the authoritative inventory and rejects unregistered test
scripts. `tests/build.sh` keeps the generated distribution synchronized with
the modules. `tests/schema.sh` requires Mike Farah `yq` v4 and Python's
`jsonschema` package. CI installs ShellCheck, SQLite, yq, and jsonschema, then
also compiles every Bash source with the official `bash:4.3.48` container to
protect the documented compatibility floor; do not claim a check ran locally if
its tool is unavailable. CI builds the public Docker Action and the production
runtime image, including the separately opt-in Docker socket test. Tests
isolate external programs with PATH shims and temporary directories—preserve
that pattern.

## Keep this skill current

When a project change alters an interface, check type, CLI command, persistence
rule, required tool, CI command, or test convention described here, update this
`SKILL.md` in the same change and validate it. Do not update the skill for
unrelated implementation detail or editorial-only changes.

## Keep the GitHub Wiki current

Review `wiki/` for **every** project change and update the affected Wiki page
in the same change. Public configuration, CLI, check, notification,
remediation, reliability, persistence, deployment, security, dependency, or
test changes must include accurate Wiki guidance and a safe, runnable example
when one helps an operator. Do not leave examples, navigation, or operational
advice stale; update `wiki/_Sidebar.md` whenever a page is added, renamed, or
removed. For an internal-only change, update the relevant verification or
troubleshooting guidance if it changes how maintainers or operators should
validate or diagnose the project.
