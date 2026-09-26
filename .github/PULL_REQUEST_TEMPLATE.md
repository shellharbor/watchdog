## Summary

<!-- What changed and why? Keep the change focused. -->

## Safety and compatibility

- [ ] New behavior is opt-in or preserves existing semantics.
- [ ] No secrets, private endpoints, or sensitive logs were added.
- [ ] YAML commands remain direct argv arrays; no `eval` or configured `bash -c` was introduced.
- [ ] Dry-run, read-only, maintenance, dependency, and parallel-check behavior was considered.

## Verification

- [ ] Focused test(s):
- [ ] `bash -n service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh`
- [ ] `shellcheck service-watchdog.sh watchdog-discover.sh install.sh tests/*.sh`
- [ ] `bash ./tests/versioning.sh`
- [ ] `bash ./tests/run-all.sh`

## Documentation

- [ ] JSON Schema/config examples/README were updated where applicable.
- [ ] Relevant Wiki pages and `wiki/_Sidebar.md` were reviewed and updated.
- [ ] `CHANGELOG.md` was updated for user-visible changes.
