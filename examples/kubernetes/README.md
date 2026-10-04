# Kubernetes values example

[`values.yaml`](values.yaml) configures the Watchdog Helm chart as a suspended,
non-root CronJob. It intentionally refers to an existing `watchdog-state` PVC
and `watchdog-notification-env` Secret; create and secure those resources in
your target namespace before installing.

```bash
helm lint charts/watchdog --strict -f examples/kubernetes/values.yaml
helm upgrade --install watchdog ./charts/watchdog -n monitoring \
  -f examples/kubernetes/values.yaml
```

Run a validation Job and inspect its output before setting
`schedule.suspend: false`. The Secret must contain only variables named by
Watchdog's `*_env` configuration fields; neither this file nor Helm values
should contain notification passwords or tokens.
