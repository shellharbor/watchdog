#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys

from jsonschema import Draft202012Validator


root = pathlib.Path(sys.argv[1])
schema_path = root / "schema" / "watchdog.schema.json"
schema = json.loads(schema_path.read_text(encoding="utf-8"))
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)


def yaml_as_json(path):
    result = subprocess.run(
        ["yq", "eval", "-o=json", ".", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"{path}: yq failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def schema_errors(path):
    return sorted(
        validator.iter_errors(yaml_as_json(path)),
        key=lambda error: (list(map(str, error.absolute_path)), error.message),
    )


annotation = (
    "# yaml-language-server: "
    "$schema=https://raw.githubusercontent.com/shellharbor/watchdog/main/schema/watchdog.schema.json"
)
valid_paths = [root / "config.example.yaml", *sorted((root / "examples").glob("*.yaml"))]
for path in valid_paths:
    if path.read_text(encoding="utf-8").splitlines()[0] != annotation:
        raise AssertionError(f"{path}: missing first-line schema annotation")
    errors = schema_errors(path)
    if errors:
        error = errors[0]
        location = ".".join(map(str, error.absolute_path)) or "<root>"
        raise AssertionError(f"{path}: {location}: {error.message}")

invalid_paths = sorted((root / "tests" / "fixtures" / "invalid").glob("*.yaml"))
if not invalid_paths:
    raise AssertionError("No negative schema fixtures found")
expected_fields = {
    "check-and-health": "services[0]",
    "check-type": "services[0].check.type",
    "email-secrets": "notifications.email.smtp.password_env",
    "maintenance-time": "maintenance.windows[0].time",
    "missing-command": "services[0].check.commands",
    "only-if-days": "services[0].only_if[0].days",
    "tcp-port": "services[0].check.port",
}
for path in invalid_paths:
    if not schema_errors(path):
        raise AssertionError(f"{path}: schema unexpectedly accepted negative fixture")
    result = subprocess.run(
        ["bash", str(root / "service-watchdog.sh"), "validate", "-c", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 2:
        raise AssertionError(
            f"{path}: validate returned {result.returncode}, expected 2: "
            f"{result.stdout} {result.stderr}"
        )
    expected_field = expected_fields.get(path.stem)
    if not expected_field or expected_field not in result.stdout + result.stderr:
        raise AssertionError(f"{path}: validate did not identify the invalid field")

print(f"Schema test passed: {len(valid_paths)} examples and {len(invalid_paths)} negative fixtures")
PY
