# ShellHarbor Watchdog Helm chart

Run the existing Watchdog image as a finite Kubernetes `CronJob`, or create one
explicit manual `Job` for `validate`, `status`, or `notify-test`. The chart
requires Helm 3 and Kubernetes 1.31 or newer. It is intended for the same
namespace that owns the Watchdog state PVC.

The default schedule is **suspended**. Review the Watchdog YAML, provision or
select durable state, validate the rendered chart, and run a manual validation
Job before enabling monitoring:

```bash
cp examples/kubernetes/values.yaml values.yaml
helm lint charts/watchdog --strict -f values.yaml
helm upgrade --install watchdog ./charts/watchdog -n monitoring -f values.yaml \
  --set manual.enabled=true
kubectl -n monitoring wait --for=condition=complete job/watchdog-watchdog-validate --timeout=10m
kubectl -n monitoring logs job/watchdog-watchdog-validate
```

Disable the completed manual Job before later upgrades, then create a one-off
Job from the CronJob to exercise real monitoring before setting
`schedule.suspend: false`. The CronJob's exit code is the monitoring result.
Kubernetes does not consume the image `HEALTHCHECK`: completed Job status,
Watchdog exit codes, Watchdog notifications, metrics, and `status` output
remain the operational signals.

## Safety and persistence

The chart creates no RBAC resources, does not mount a service-account token,
uses no `hostPath`, Docker socket, host network, or privileged container, and
runs as UID/GID `10001` with a read-only root filesystem, RuntimeDefault seccomp
and all Linux capabilities dropped. It deliberately does not support local
`systemctl` commands or Docker socket remediation. Prefer Watchdog's remote HTTP
remediation for Kubernetes-facing recovery actions.

`state.persistence: true` creates a retained PVC by default. Watchdog needs that
state to preserve failure and recovery transitions across CronJob Pods. Set
`state.existingClaim` to an operator-owned claim when storage lifecycle is
managed elsewhere. Disable persistence only when transition continuity is not
required. Existing state volumes must be writable by UID/GID `10001` or support
the chart's `fsGroup: 10001` setting.

The chart never creates Kubernetes Secrets. Keep all `*_env` references in
`config`, create a Secret separately, and set `envFromSecret` to its name. Pin
production images with `image.digest`; otherwise the chart defaults to the
version published in `Chart.appVersion`.

See the full [Kubernetes deployment guide](../../wiki/Kubernetes-Deployment.md)
and the [values example](../../examples/kubernetes/values.yaml) before enabling
the schedule.
