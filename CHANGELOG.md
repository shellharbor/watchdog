# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/shellharbor/watchdog/compare/v1.0.6...HEAD
[1.0.6]: https://github.com/shellharbor/watchdog/compare/v1.0.3...v1.0.6
[1.0.3]: https://github.com/shellharbor/watchdog/releases/tag/v1.0.3
