# Releasing ShellHarbor Watchdog

This project keeps release metadata deliberately simple and verifiable. The
root [`VERSION`](VERSION) file is the source for the CLI version; the README
and changelog are derived release documentation checked by CI.

## Release checklist

1. Confirm the working tree contains only intended changes.
2. Set `VERSION` to the next semantic version without the `v` prefix.
3. Add a dated `## [X.Y.Z]` section to [`CHANGELOG.md`](CHANGELOG.md).
4. Update the stable archive URL and extracted directory name in `README.md`.
5. Update affected Wiki pages and examples.
6. Run the quality checks:

   ```bash
   bash ./scripts/build-watchdog.sh --check
   bash ./scripts/release-preflight.sh vX.Y.Z
   bash -n service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh scripts/release-preflight.sh lib/watchdog/*.sh tests/*.sh
   shellcheck service-watchdog.sh watchdog-discover.sh install.sh scripts/build-watchdog.sh scripts/release-preflight.sh tests/*.sh
   bash ./tests/versioning.sh
   bash ./tests/run-all.sh
   # When changing the Helm chart or Kubernetes runtime contract:
   helm lint charts/watchdog --strict
   python3 ./tests/kubernetes_chart.py
   python3 ./tests/kubernetes_integration.py
   ```

7. Commit the release metadata and create an annotated `vX.Y.Z` tag.
8. Push the commit and tag. The `Release metadata` workflow reruns the same
   preflight and verifies tag, `VERSION`, CLI output, README archive reference,
   changelog heading, and installer metadata.
9. Create the GitHub release from the verified tag and paste the matching
   changelog entry as its release notes.

The `Kubernetes` workflow supplies pinned Helm, kind, kubectl, and PyYAML in an
isolated runner. It should be green for a Kubernetes-facing release; its kind
test uses a private kubeconfig and a temporary cluster only.

Do not move or retag an already published release. Publish a corrective patch
release instead.
