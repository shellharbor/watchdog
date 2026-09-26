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
- `actions.http` is first-class remote remediation, not a shell escape hatch.
  It shares all ordinary remediation guards and in enforce mode must match an
  exact `security.remediation_policy.allowed_http` method/URL entry. Header and
  body secrets use `*_env` and private temporary files.
- `action.yml` is the public Docker Action for CI configuration validation. It
  must invoke only `validate`, keep its config path inside `GITHUB_WORKSPACE`,
  and exit with Watchdog's normal validation status. Keep its image dependencies
  sufficient for every optional check type and cover its valid and invalid
  behavior through `tests/github-action.sh --docker` in CI.
- `status_page.uptime` is opt-in and requires `history.enabled: true`. It
  renders only sampled, observed availability from history: preserve grey
  intervals when no record exists and never present the bars as an SLA.
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
bash -n service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh lib/watchdog/*.sh tests/*.sh
bash -n scripts/github-action-entrypoint.sh
shellcheck service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh scripts/github-action-entrypoint.sh tests/*.sh
bash ./tests/versioning.sh
bash ./tests/run-all.sh
```

`tests/run-all.sh` is the authoritative inventory and rejects unregistered test
scripts. `tests/build.sh` keeps the generated distribution synchronized with
the modules. `tests/schema.sh` requires Mike Farah `yq` v4 and Python's
`jsonschema` package. CI installs ShellCheck, SQLite, yq, and jsonschema, then
also compiles every Bash source with the official `bash:4.3.48` container to
protect the documented compatibility floor; do not claim a check ran locally if
its tool is unavailable. Tests isolate external programs with PATH shims and
temporary directories—preserve that pattern.

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
