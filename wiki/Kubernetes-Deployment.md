# Kubernetes deployment

Watchdog runs one complete monitoring cycle and exits. In Kubernetes that maps
to a finite `batch/v1` CronJob, not a Deployment, Service, controller, or
always-running probe process. The Helm chart under
[`charts/watchdog`](../charts/watchdog) requires Helm 3 and Kubernetes 1.31+.

The chart uses the same production image, YAML configuration, environment-based
secrets, state semantics, and `0`/`1`/`2` exit codes as native and Docker
deployments. A completed Job says Watchdog itself ran; an exit code of `1`
still means Watchdog successfully observed an unavailable target or attempted
remediation. Use Watchdog notifications, Prometheus metrics, and the persisted
`status` command for service health.

## Before installing

- Install in the namespace that owns the state PVC. A mounted PVC is normally
  required to retain failure/recovery transitions and the existing lock across
  CronJob Pods.
- Adapt the Watchdog configuration; the sample URL is deliberately invalid for
  production. Validate the final YAML with the same `validate` command used in
  other deployment modes.
- Decide who owns storage. The default chart creates a retained state PVC;
  `state.existingClaim` instead references an existing operator-owned claim.
- Create notification secrets outside Helm. The chart only references an
  existing Secret by name and never creates a Secret or renders a value.

## First installation

Copy the values example and replace the endpoint. It intentionally starts with
the schedule suspended:

```bash
cp examples/kubernetes/values.yaml values.yaml
chmod 0600 values.yaml
helm lint charts/watchdog --strict -f values.yaml

kubectl create namespace monitoring
helm upgrade --install watchdog ./charts/watchdog \
  --namespace monitoring \
  --create-namespace \
  --values values.yaml \
  --set manual.enabled=true
```

The optional manual Job runs the literal arguments in `manual.args`; by default
that is `validate`. Watch it complete before enabling the regular schedule:

```bash
kubectl -n monitoring wait --for=condition=complete \
  job/watchdog-watchdog-validate --timeout=10m
kubectl -n monitoring logs job/watchdog-watchdog-validate

# Remove the completed manual Job from Helm management before the next change.
helm upgrade watchdog ./charts/watchdog -n monitoring -f values.yaml \
  --set manual.enabled=false

# Run one real cycle on demand, inspect the result, then enable the schedule.
kubectl -n monitoring create job watchdog-first-cycle \
  --from=cronjob/watchdog-watchdog
kubectl -n monitoring logs --follow job/watchdog-first-cycle
helm upgrade watchdog ./charts/watchdog -n monitoring -f values.yaml \
  --set schedule.suspend=false
```

The CronJob uses `concurrencyPolicy: Forbid`, one Pod per Job, no automatic Job
retries, an active deadline, and a short history. The state lock remains useful
because an operator-created Job can otherwise overlap a scheduled cycle.

## Configuration, state, and secrets

`config` in Helm values is rendered to a ConfigMap at
`/etc/watchdog/config.yaml`. It is ordinary Watchdog YAML: use only `*_env`
fields for credentials. Do not add credentials to Helm values, a ConfigMap,
image tag, or command arguments.

Create a Secret with your approved secret-management workflow, then reference
it by name. A protected local env file is only an illustration; prefer a
cluster secret controller where one is available:

```bash
chmod 0600 notification.env
kubectl -n monitoring create secret generic watchdog-notification-env \
  --from-env-file=notification.env

# values.yaml
# envFromSecret: watchdog-notification-env
```

The default `state.persistence: true` creates `<release>-watchdog-state` and
marks it `helm.sh/resource-policy: keep`, so Helm uninstall does not silently
erase transition state. For pre-provisioned storage:

```yaml
state:
  persistence: true
  existingClaim: watchdog-state
```

The Pod runs as UID/GID `10001` and requests `fsGroup: 10001`. Ensure the CSI
driver and existing PVC permit that account to write `/var/lib/watchdog`; test
that behavior in the target cluster before unsuspending the schedule. Setting
`state.persistence: false` deliberately uses an `emptyDir`: each Pod then
forgets prior transitions, which is rarely suitable for alerting.

## Security boundary

The chart is intentionally boring and narrowly scoped:

- UID/GID `10001`, read-only root filesystem, RuntimeDefault seccomp,
  `allowPrivilegeEscalation: false`, and every Linux capability dropped.
- No RBAC objects or ServiceAccount token mount; Watchdog has no Kubernetes API
  credentials.
- No `hostPath`, host networking, privileged mode, Docker socket, or Docker
  CLI image/profile.
- A bounded writable `/tmp` and an explicit writable state volume are the only
  writable paths.

This means local host-only actions are unavailable: `systemctl` cannot reach a
node service, `127.0.0.1` is the Watchdog Pod, and Docker remediation cannot
talk to a node daemon. Use Watchdog's existing remote HTTP remediation or
platform-native automation for those actions. Do not broaden the Pod's
privileges merely to make a host feature appear to work.

## Image pinning, upgrade, and rollback

The chart defaults to `ghcr.io/shellharbor/watchdog` and its matching
`Chart.appVersion`. Pin deployments to an immutable published digest once it
has been verified:

```yaml
image:
  repository: ghcr.io/shellharbor/watchdog
  digest: sha256:replace-with-a-verified-64-character-digest
```

Keep the prior values file and image digest. Upgrade only after linting and a
manual validation Job; `helm rollback watchdog <revision> -n monitoring`
restores the previous chart configuration while the retained state PVC keeps
the incident ledger. Kubernetes job history is not a replacement for Watchdog
state or notification history.

## CI verification

The [Kubernetes workflow](../.github/workflows/kubernetes.yml) validates the
chart with strict Helm linting and rendered safety tests, then builds the real
runtime image and exercises it in a disposable kind cluster. The test uses a
private temporary kubeconfig, creates only its randomly named kind cluster,
checks a successful cycle, persistent state, no Docker socket, and invalid
configuration exit status, then deletes that cluster. It never contacts a
maintainer or production cluster.

For the closest local verification, install Helm, kind, kubectl, and PyYAML:

```bash
helm lint charts/watchdog --strict
python3 tests/kubernetes_chart.py
python3 tests/kubernetes_integration.py
```

The final command creates and deletes an isolated kind cluster and therefore
needs a reachable local Docker daemon.
