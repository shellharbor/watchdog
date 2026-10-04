#!/usr/bin/env python3
"""Render the Watchdog Helm contract and test its safety gates without a cluster."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "watchdog"
HELM = os.environ.get("HELM", "helm")


def render(values=None, release="watchdog", version="1.34.0"):
    with tempfile.TemporaryDirectory(prefix="watchdog-chart-") as directory:
        arguments = [HELM, "template", release, str(CHART), "--kube-version", version]
        if values is not None:
            path = Path(directory) / "values.yaml"
            path.write_text(yaml.safe_dump(values), encoding="utf-8")
            arguments += ["-f", str(path)]
        return subprocess.run(arguments, text=True, capture_output=True, check=False)


def documents(values=None, **kwargs):
    result = render(values, **kwargs)
    if result.returncode:
        raise AssertionError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def pod_spec(item):
    if item["kind"] == "CronJob":
        return item["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return item["spec"]["template"]["spec"]


class ChartContract(unittest.TestCase):
    def reject(self, values, fragment, **kwargs):
        result = render(values, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_version_and_supported_kubernetes(self):
        chart = yaml.safe_load((CHART / "Chart.yaml").read_text(encoding="utf-8"))
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        self.assertEqual(chart["appVersion"], version)
        for kube_version in ("1.31.0", "1.34.0"):
            with self.subTest(kube_version=kube_version):
                self.assertTrue(documents(version=kube_version))
        self.reject({}, "kubeVersion", version="1.30.0")

    def test_default_cronjob_is_finite_and_least_privileged(self):
        items = documents()
        self.assertEqual({item["kind"] for item in items}, {"ConfigMap", "CronJob", "PersistentVolumeClaim"})
        cron = next(item for item in items if item["kind"] == "CronJob")
        self.assertTrue(cron["spec"]["suspend"])
        self.assertEqual(cron["spec"]["concurrencyPolicy"], "Forbid")
        job = cron["spec"]["jobTemplate"]["spec"]
        self.assertEqual((job["backoffLimit"], job["parallelism"], job["completions"]), (0, 1, 1))
        self.assertGreater(job["activeDeadlineSeconds"], 0)
        self.assertGreaterEqual(job["ttlSecondsAfterFinished"], 0)

        pod = pod_spec(cron)
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual(pod["restartPolicy"], "Never")
        self.assertEqual(pod["securityContext"]["runAsUser"], 10001)
        self.assertEqual(pod["securityContext"]["runAsGroup"], 10001)
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        self.assertEqual(pod["securityContext"]["seccompProfile"], {"type": "RuntimeDefault"})
        self.assertNotIn("serviceAccountName", pod)
        self.assertFalse(any("hostPath" in volume for volume in pod["volumes"]))
        self.assertNotIn("hostNetwork", pod)

        container = pod["containers"][0]
        self.assertNotIn("command", container)
        self.assertNotIn("args", container)
        self.assertTrue(container["image"].endswith(":1.7.8"))
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertNotIn("privileged", container["securityContext"])
        self.assertTrue(container["resources"]["requests"])
        self.assertTrue(container["resources"]["limits"])
        mounts = {mount["name"]: mount for mount in container["volumeMounts"]}
        self.assertTrue(mounts["config"]["readOnly"])
        self.assertFalse(mounts["state"].get("readOnly", False))
        config_volume = next(volume["configMap"] for volume in pod["volumes"] if volume["name"] == "config")
        self.assertEqual(config_volume["defaultMode"], 292)
        state_volume = next(volume for volume in pod["volumes"] if volume["name"] == "state")
        self.assertIn("persistentVolumeClaim", state_volume)

        pvc = next(item for item in items if item["kind"] == "PersistentVolumeClaim")
        self.assertEqual(pvc["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
        self.assertNotIn("storageClassName", pvc["spec"])

    def test_existing_or_ephemeral_state_is_explicit(self):
        existing = documents({"state": {"existingClaim": "shared-watchdog-state"}})
        self.assertFalse(any(item["kind"] == "PersistentVolumeClaim" for item in existing))
        pod = pod_spec(next(item for item in existing if item["kind"] == "CronJob"))
        state = next(volume["persistentVolumeClaim"] for volume in pod["volumes"] if volume["name"] == "state")
        self.assertEqual(state["claimName"], "shared-watchdog-state")

        ephemeral = documents({"state": {"persistence": False}})
        self.assertFalse(any(item["kind"] == "PersistentVolumeClaim" for item in ephemeral))
        pod = pod_spec(next(item for item in ephemeral if item["kind"] == "CronJob"))
        state = next(volume for volume in pod["volumes"] if volume["name"] == "state")
        self.assertEqual(state["emptyDir"], {})

    def test_secret_reference_image_digest_and_typed_environment(self):
        digest = "sha256:" + "a" * 64
        values = {
            "image": {"digest": digest},
            "envFromSecret": "watchdog-runtime-env",
            "env": {"COUNT": 3, "ENABLED": True},
            "imagePullSecrets": [{"name": "registry-auth"}],
            "nodeSelector": {"kubernetes.io/os": "linux", "watchdog": "enabled"},
            "tolerations": [{"key": "monitoring", "operator": "Exists"}],
        }
        pod = pod_spec(next(item for item in documents(values) if item["kind"] == "CronJob"))
        container = pod["containers"][0]
        self.assertTrue(container["image"].endswith("@" + digest))
        self.assertEqual(container["envFrom"], [{"secretRef": {"name": "watchdog-runtime-env"}}])
        self.assertTrue(all(isinstance(item["value"], str) for item in container["env"]))
        self.assertEqual(pod["imagePullSecrets"], [{"name": "registry-auth"}])
        self.assertEqual(pod["nodeSelector"]["watchdog"], "enabled")
        self.assertEqual(pod["tolerations"], [{"key": "monitoring", "operator": "Exists"}])

    def test_manual_job_uses_literal_argv(self):
        values = {
            "schedule": {"enabled": False},
            "manual": {"enabled": True, "name": "status", "args": ["status", "--json"]},
        }
        job = next(item for item in documents(values) if item["kind"] == "Job")
        self.assertEqual(job["spec"]["template"]["spec"]["containers"][0]["args"], ["status", "--json"])

        literal = ["notify-test", "--channel", "$(touch /tmp/not-a-shell)", "{{ not_a_template }}"]
        job = next(item for item in documents({"schedule": {"enabled": False}, "manual": {"enabled": True, "args": literal}})
                   if item["kind"] == "Job")
        self.assertEqual(job["spec"]["template"]["spec"]["containers"][0]["args"], literal)

    def test_examples_and_invalid_values(self):
        examples = sorted((ROOT / "examples" / "kubernetes").glob("*.yaml"))
        self.assertTrue(examples)
        for path in examples:
            with self.subTest(path=path.name):
                self.assertTrue(documents(yaml.safe_load(path.read_text(encoding="utf-8"))))

        invalid_cases = (
            ({"unexpected": True}, "unexpected"),
            ({"image": {"digest": "sha256:not-a-digest"}}, "'/image/digest'"),
            ({"state": {"persistence": False, "existingClaim": "state"}}, "existingClaim"),
            ({"manual": {"name": "UPPER"}}, "'/manual/name'"),
            ({"schedule": {"value": "daily"}}, "'/schedule/value'"),
            ({"securityContext": {"privileged": True}}, "securityContext"),
        )
        for values, fragment in invalid_cases:
            with self.subTest(values=values):
                self.reject(values, fragment)


if __name__ == "__main__":
    unittest.main(verbosity=2)
