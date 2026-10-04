# ADR 0002: Run Watchdog as scoped Kubernetes CronJobs

## Status

Accepted — 2026-10-04.

## Context

Watchdog already has a production non-root container image and is deliberately
a finite monitor. A Kubernetes Deployment, liveness probe, or always-running
controller would misrepresent that lifecycle: each scheduled monitoring cycle
must complete, persist transition state, and report its own `0`/`1`/`2` exit
status.

## Decision

Ship a Helm 3 chart for Kubernetes 1.31+ that creates a suspended-by-default
`batch/v1` CronJob and an optional manual Job. It mounts a ConfigMap-generated
Watchdog configuration, a durable state PVC by default, and a bounded `/tmp`
`emptyDir`. Existing Secrets can supply only environment values referenced by
the existing `*_env` fields; Helm never creates or renders secret values.

Each Job has one Pod, no retries, a deadline, and a `Forbid` CronJob concurrency
policy. Persistent state remains the authoritative cross-Job lock and
transition ledger. Pods run as UID/GID `10001` with a read-only root filesystem,
RuntimeDefault seccomp, no privilege escalation, and all capabilities dropped.
No ServiceAccount token, RBAC, Kubernetes API access, host networking,
`hostPath`, Docker socket, or privileged profile is included.

## Consequences

- A completed Job's condition and container exit code are Watchdog health
  signals; Docker `HEALTHCHECK` is not a Kubernetes readiness signal.
- The chart preserves configuration-only monitoring. It cannot control host
  systemd services or a node's Docker daemon; use remote HTTP remediation or
  narrowly scoped platform automation for Kubernetes recovery actions.
- Durable state needs a writable compatible PVC. Disabling persistence loses
  transition continuity between Pods and is therefore an explicit trade-off.
- The chart does not discover Kubernetes resources or generate Secrets. It is
  a portable scheduled-container surface, not a cluster controller.

## Validation

Rendering tests assert version coupling, Job lifecycle, no privilege/RBAC/host
access, ConfigMap/Secret/PVC behavior, manual literal argv handling, examples,
and invalid chart values. The Kubernetes workflow builds the actual runtime
image and runs a representative cycle, persisted state check, and invalid
configuration check inside an isolated kind cluster with a private kubeconfig.
