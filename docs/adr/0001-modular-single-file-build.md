# ADR 0001: Modular source with a generated single-file distribution

## Status

Accepted — 2026-09-26.

## Context

Watchdog is deliberately installed as one Bash script, but maintaining several
thousand lines in one source file made review and ownership of configuration,
checks, state handling, and CLI behavior unnecessarily difficult.

## Decision

Maintain the ordered source modules in `lib/watchdog/` and generate the tracked
`service-watchdog.sh` distribution with `scripts/build-watchdog.sh`. The
generated file remains the only monitor artifact used by the installer and
systemd. It does not source files at runtime.

`scripts/build-watchdog.sh --check` renders a temporary distribution and fails
when the tracked artifact is stale. CI and the regression suite run this check.

## Consequences

- Contributors edit the smallest relevant module, then regenerate the
  distribution before committing.
- Deployments retain the existing single-file installation and no new runtime
  dependency or lookup path.
- Module order is part of the build contract; functions may refer to later
  definitions because the generated file is parsed before `main` runs.
