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
   bash -n service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh
   shellcheck service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh
   bash ./tests/versioning.sh
   bash ./tests/run-all.sh
   ```

7. Commit the release metadata and create an annotated `vX.Y.Z` tag.
8. Push the commit and tag. The `Release metadata` workflow verifies tag,
   `VERSION`, CLI output, README archive reference, and changelog heading.
9. Create the GitHub release from the verified tag and paste the matching
   changelog entry as its release notes.

Do not move or retag an already published release. Publish a corrective patch
release instead.
