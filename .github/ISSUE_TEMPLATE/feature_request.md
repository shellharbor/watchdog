---
name: Feature request
about: Propose a focused improvement to Watchdog
title: "feature: "
labels: enhancement
assignees: ""
---

## Problem

What operational problem cannot be solved with the current configuration,
existing checks, hooks, or examples?

## Proposed behavior

Show a small redacted YAML or CLI example when possible. New behavior should be
opt-in and preserve the one-shot Linux/Bash model.

```yaml
# Example configuration, without secrets or private endpoints
```

## Alternatives considered

Describe existing checks, hooks, scheduler configuration, or external tools you
considered.

## Safety and compatibility

- Would this execute commands, write files, or make network requests?
- Does it require an optional dependency?
- How should it behave with `--dry-run`, maintenance, dependencies, and
  parallel checks?
