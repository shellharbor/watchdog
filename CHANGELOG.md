# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.7.0] - 2026-09-26

### Added

- A self-contained GitHub Action for read-only Watchdog configuration
  validation in pull requests and deployment workflows.

## [1.6.0] - 2026-09-26

### Added

- Optional DNS record checks through `dig` and ICMP reachability checks through
  Linux `ping`, including answer, packet-loss, and average-RTT thresholds.
- PagerDuty and Opsgenie on-call notifications with incident-ID deduplication
  and automatic recovery resolution.
- Remote HTTP remediation with timeout/status validation, secret-safe temporary
  request files, and exact method/URL allowlisting in enforce mode.

## [1.5.0] - 2026-09-26

### Added

- Opt-in Status Page observed-availability bars backed by existing JSONL or
  SQLite history. They render the latest sampled result across configurable
  trailing-day intervals without introducing a web service or UI dependency.

### Changed

- Watchdog's maintainable source is now split into ordered `lib/watchdog/`
  modules while the installer and deployments continue to use the generated,
  self-contained `service-watchdog.sh` distribution. The build and release
  checks reject a stale generated script.
- Watchdog now snapshots the parsed configuration in memory and serves simple
  scalar, type, length, and map-entry lookups from that cache. The cache is
  rebuilt after template expansion, inherited by parallel check workers, and
  safely falls back to `yq` for complex expressions.
- Added a regression test that proves template validation remains correct while
  bounding configuration-parser invocations.

### Fixed

- Restored cache matching for dotted configuration paths and numeric array
  indexes, and preserved empty cache fields while loading maps and sequences.
  Ordinary reads no longer fall back to `yq` or mistake configured services for
  an empty list.

## [1.4.0] - 2026-09-26

### Added

- Opt-in `tls_cert` checks that alert when a TLS leaf certificate has fewer
  than the configured whole days remaining before expiry. They support a
  custom port and SNI name, reuse normal transition notifications, and report
  the expiry timestamp and `days_remaining` without persisting certificate data.
- A schema-annotated TLS certificate example, negative schema coverage, and
  deterministic OpenSSL-shim regression tests.

## [1.3.0] - 2026-09-26

### Added

- An OpenSSF Scorecard GitHub Actions workflow that publishes signed supply-chain
  security results to GitHub Code Scanning and the public Scorecard service,
  plus a live README badge.
- A CI compatibility gate that compiles every Bash source with Bash 4.3, the
  project's documented minimum supported Bash version.

### Security

- SMTP credentials are now supplied to curl through an ephemeral mode-`0600`
  configuration file instead of process arguments. The file is removed after
  delivery, and SMTP error output redacts the password before it reaches logs.

## [1.2.0] - 2026-09-26

### Added

- Smart HTTP checks: direct request headers with secret-safe `value_env`,
  optional response content-type and bounded body-regex assertions, and a
  `max_total_ms` latency SLO.
- HTTP latency gauges for Prometheus plus a schema-annotated Smart HTTP example
  and dedicated regression coverage for assertions, secret redaction,
  degradation, no-remediation behavior, and invalid configuration.

### Changed

- A successful HTTP response that exceeds `max_total_ms` is now represented as
  `degraded`, with transition alerts and metrics but without remediation,
  circuit-breaker, backoff, flapping, escalation, or unavailable-counter side
  effects.

## [1.1.8] - 2026-09-26

### Added

- A root `VERSION` file as the single release-version source for the CLI,
  installer, documentation, and release validation.
- GitHub community documents for security reporting, contributing, support,
  release management, and a Contributor Covenant Code of Conduct, plus focused
  issue and pull-request templates.
- `tests/run-all.sh`, the authoritative full regression runner. It rejects an
  unregistered test script before executing the complete deterministic suite.
- Version-metadata regression coverage and a release-tag workflow that verifies
  the Git tag, `VERSION`, CLI output, README archive link, and changelog entry.

### Changed

- GitHub Actions now runs Bash syntax checks and ShellCheck for every test
  script, followed by the complete regression suite on pushes and pull requests.
- The Quick Start, installer, test documentation, project skill, and Wiki now
  describe the version-file and authoritative test-runner workflow.

### Fixed

- The webhook regression test no longer combines `export` with command
  substitution, keeping the full suite compatible with ShellCheck.

## [1.1.7] - 2026-09-26

### Added

- A GitHub-ready `wiki/` documentation set with runnable examples for checks,
  alerts, remediation, reliability controls, status/history, discovery,
  federation, deployment, and troubleshooting.

### Changed

- Linked the project Wiki from the README and added repository rules requiring
  Wiki guidance and examples to remain synchronized with project changes.

## [1.1.6] - 2026-09-26

### Added

- Opt-in `clamav` scanning and `threshold` checks for journald, log files,
  socket states, and direct count commands, with template and hook variables.
- Security-check regression tests and a worked configuration example.
- Opt-in per-check history in JSONL or optional SQLite storage, with daily or
  single-file retention and read-only `--report` / `--trend` terminal views.
- History and trend regression coverage in CI, plus a configuration example.
- Opt-in `disk` health checks for filesystem free space, with GiB and percent
  thresholds and the existing failure/recovery notification channels.
- Disk-space regression coverage and an all-channel configuration example.
- Draft 2020-12 JSON Schema for the monitor configuration, with editor
  annotations in the example YAML files and CI checks for valid and invalid
  configurations.
- `notify-test` sends explicit test messages through enabled email and webhook
  channels without running checks or changing monitoring state.
- Read-only `status` command with terminal and JSON summaries, maintenance and
  remediation-block visibility, and optional orphaned state files.
- Regression tests for both commands in GitHub Actions.

### Fixed

- Filesystem `only_if` conditions now compare the actual free-space percentage
  instead of the used-space percentage reported by `df`.

## [1.1.4] - 2026-09-25

### Added

- Consolidated release documentation for the renamed ShellHarbor Watchdog
  project, including HTTP/TCP/command monitoring, secure argv remediation,
  email and webhook notifications, and systemd/cron deployment.
- Opt-in maintenance windows, escalation, circuit breakers, dependency chains,
  conditional checks, templates, parallel checks, Prometheus textfile metrics,
  static status pages, federation, and offline Docker Compose/systemd discovery.
- Draft 2020-12 configuration JSON Schema, `notify-test`, read-only `status`,
  examples, automated tests, and GitHub Actions/CodeQL workflows.

## [1.0.6] - 2026-08-15

### Added

- Built-in SMTP email notifications with YAML-configured connection settings,
  recipients, and failure/recovery templates.
- Transition-only delivery: one failure message per incident and one recovery
  message when the service becomes healthy again.
- Automated coverage for email delivery and duplicate suppression.

## [1.0.3] - 2026-08-15

### Added

- HTTP, TCP, and command-based health checks.
- Configurable retries, timeouts, remediation cooldowns, and post-action checks.
- Failure and recovery hooks with structured environment variables.
- Persistent service state and a global non-blocking execution lock.
- Dry-run and single-service modes.
- systemd service/timer units and cron documentation.
- Ready-to-adapt configurations in the `examples` directory.
- GitHub Actions smoke testing and ShellCheck validation.
- `-V` and `--version` options.

### Changed

- Improved installer dependency checks, runtime directory creation, and summary.
- Quick Start now uses the stable `v1.0.3` source archive.
- Expanded repository ignore rules and troubleshooting documentation.

[Unreleased]: https://github.com/shellharbor/watchdog/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/shellharbor/watchdog/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/shellharbor/watchdog/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/shellharbor/watchdog/compare/v1.1.8...v1.2.0
[1.1.8]: https://github.com/shellharbor/watchdog/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/shellharbor/watchdog/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/shellharbor/watchdog/compare/v1.1.4...v1.1.6
[1.1.4]: https://github.com/shellharbor/watchdog/compare/v1.0.6...v1.1.4
[1.0.6]: https://github.com/shellharbor/watchdog/compare/v1.0.3...v1.0.6
[1.0.3]: https://github.com/shellharbor/watchdog/releases/tag/v1.0.3
