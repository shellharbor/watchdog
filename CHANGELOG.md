# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/shellharbor/watchdog/compare/v1.1.8...HEAD
[1.1.8]: https://github.com/shellharbor/watchdog/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/shellharbor/watchdog/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/shellharbor/watchdog/compare/v1.1.4...v1.1.6
[1.1.4]: https://github.com/shellharbor/watchdog/compare/v1.0.6...v1.1.4
[1.0.6]: https://github.com/shellharbor/watchdog/compare/v1.0.3...v1.0.6
[1.0.3]: https://github.com/shellharbor/watchdog/releases/tag/v1.0.3
