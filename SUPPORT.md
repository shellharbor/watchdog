# Support

Use the channel that best matches the request so operators can get help without
turning configuration questions into incomplete bug reports.

## Documentation and configuration help

Start with the [Wiki](wiki/Home.md), [`README.md`](README.md),
[`config.example.yaml`](config.example.yaml), and the ready-to-adapt
[`examples/`](examples). Useful first commands are:

```bash
bash ./service-watchdog.sh validate -c ./config.yaml
bash ./service-watchdog.sh -c ./config.yaml --dry-run
bash ./service-watchdog.sh status -c ./config.yaml --all
bash ./service-watchdog.sh notify-test -c ./config.yaml --channel all
```

If the documentation does not answer the question, open a
[GitHub Discussion](https://github.com/shellharbor/watchdog/discussions) when
available, or a GitHub issue with the `question` label.

## Bugs and feature requests

Use the corresponding issue template. Include the Watchdog version, Linux and
`yq` versions, exact command and exit code, expected versus actual behavior,
and a minimal redacted configuration. Do not include sensitive values.

## Security reports

Do not use public discussions or issues for a suspected vulnerability. Follow
[SECURITY.md](SECURITY.md) instead.

## What support cannot diagnose

Without a minimal reproduction, the project cannot safely diagnose private
network reachability, a provider's hidden webhook policy, privileged remediation
commands, or a production system's permissions. Redact details, reduce the
case, and confirm the behavior with `validate` or `--dry-run` first.
