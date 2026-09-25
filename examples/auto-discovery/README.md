# Auto-discovery example

From the repository root, run:

```bash
bash ./watchdog-discover.sh -c ./examples/auto-discovery/discovery.yaml --dry-run
```

`generated-watchdog.yaml` shows the expected service checks. The tool emits
quoted YAML strings and diagnostic counts on stderr. This is a draft, not an
automatically loaded `config.d` file; review and merge it into the active
watchdog config. No Docker daemon, systemd instance, or containers are needed
to run this example.
