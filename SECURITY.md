# Security Policy

ShellHarbor Watchdog can run health checks, deliver alerts, and—when explicitly
configured—execute remediation commands. Security reports involving credentials,
command execution, configuration parsing, filesystem access, webhook delivery,
or state handling are handled privately.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest `1.1.x` release | Yes |
| Earlier releases | No |

Please upgrade to the latest release before reporting an issue that may already
be fixed. The current release version is recorded in [`VERSION`](VERSION).

## Reporting a vulnerability

Do **not** open a public GitHub issue for a suspected vulnerability and do not
include real passwords, tokens, webhook URLs, hostnames, IP addresses, incident
files, or production configuration.

Use one of these private channels instead:

1. [Open a private GitHub security advisory](https://github.com/shellharbor/watchdog/security/advisories/new).
2. Email [sovletig@gmail.com](mailto:sovletig@gmail.com) with the subject
   `Watchdog security report`.

Include a concise description, affected version or commit, reproduction steps,
impact, and a minimal redacted configuration. A safe proof of concept is more
useful than a destructive exploit. Maintainers will acknowledge the report,
coordinate a fix and disclosure, and credit reporters when they want credit.

## Scope and security expectations

High-priority reports include, but are not limited to:

- execution of YAML values through a shell or bypass of the remediation
  allowlist;
- exposure of `*_env` secret values in logs, state, metrics, history, status
  pages, generated reports, or error messages;
- unsafe filesystem writes, path traversal, symlink bypasses, or permission
  escalation by the installer or runtime;
- configuration parsing that enables unexpected commands, webhook requests, or
  external network access;
- authentication or integrity weaknesses in federation report handling.

The following are usually operational support matters rather than security
vulnerabilities: a missing optional dependency, a misconfigured endpoint,
expected access denied errors from the operating system, or an administrator
intentionally allowing an unsafe remediation command. If unsure, report it
privately and the maintainers will triage it.

## Secure deployment checklist

- Keep configuration, `VERSION`, scripts, systemd environment files, state,
  history, and lock directories owned by a trusted administrator.
- Store credentials only in `*_env` variables or protected secret stores;
  never commit them to YAML, examples, logs, or issues.
- Use direct argv arrays for commands. Do not add `eval`, shell strings, or
  configured `bash -c` wrappers.
- Prefer `security.remediation_policy.mode: enforce` and allowlist each exact
  remediation/escalation command vector.
- Run the monitor with the least privilege necessary. A remediation allowlist
  is a guardrail, not a sandbox for a privileged account.
- Run `validate`, `--dry-run`, and `notify-test` before scheduling a changed
  production configuration.

See [Security notes in the README](README.md#security-notes) and the
[Security Monitoring Wiki guide](wiki/Checks-and-Security.md) for deployment
examples.
