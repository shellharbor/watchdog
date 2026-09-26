# Contributing to ShellHarbor Watchdog

Thank you for helping make Watchdog more reliable and safer to operate. Small,
focused contributions are preferred: a clear bug fix, a new test, a documented
example, or a narrowly scoped check improvement is easier to review and safer
to deploy than a broad rewrite.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) and follow the project
security boundaries below.

## Before opening an issue

- Search existing issues and the [Wiki](wiki/Home.md).
- Test the current `main` branch or latest release.
- Run `validate` and `--dry-run` with a redacted minimal configuration.
- Never include passwords, tokens, webhook URLs, internal hostnames, IP
  addresses, private incident history, or production logs containing sensitive
  information. Use [SECURITY.md](SECURITY.md) for suspected vulnerabilities.

## Development setup

```bash
git clone https://github.com/shellharbor/watchdog.git
cd watchdog
bash ./service-watchdog.sh --version
bash ./service-watchdog.sh validate -c ./config.example.yaml
```

The runtime targets Linux with Bash 4.3+, Mike Farah `yq` v4, `curl`, `flock`,
and GNU coreutils. CI additionally provides ShellCheck, SQLite, and Python's
`jsonschema` package.

## Contribution workflow

1. Start from a current branch and keep one logical concern per pull request.
2. Read the root [`SKILL.md`](SKILL.md) before changing monitor behavior. It
   records project-specific safety, state, parallelism, and test conventions.
3. Add focused automated coverage in `tests/` for every observable behavior.
   External programs belong behind PATH shims or local test servers.
4. Update configuration/schema/examples/docs together when the public contract
   changes. Review and update the relevant `wiki/` page in the same change.
5. Keep secrets out of every committed file and output. Commands in YAML remain
   direct argv arrays—never add `eval` or configured `bash -c`.
6. Explain the user-visible behavior, compatibility impact, tests, and any
   unavailable local checks in the pull request description.

## Quality checks

Run the narrowest relevant test first, then the complete suite:

```bash
bash -n service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh
shellcheck service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh
bash ./tests/versioning.sh
bash ./tests/run-all.sh
```

`tests/run-all.sh` is the authoritative inventory. It fails when a test script
is not registered, then runs every scenario. `tests/schema.sh` needs `yq` v4
and Python `jsonschema`; CI installs them. Do not claim an unavailable local
tool passed—state the exact blocker instead.

## Pull request expectations

- Preserve Linux/Bash 4.3 compatibility and the exit-code contract (`0`, `1`,
  `2`).
- Keep new behavior opt-in and avoid breaking state-file names, metric names,
  defaults, or existing YAML semantics.
- Add validation for new configuration fields and synchronize the JSON Schema,
  `config.example.yaml`, examples, README, Wiki, changelog, and CI as needed.
- Preserve dry-run, read-only, maintenance, dependency, and parallel-check
  semantics.
- Do not combine unrelated formatting churn with functional changes.

For support questions or configuration help, see [SUPPORT.md](SUPPORT.md).
