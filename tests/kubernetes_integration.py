#!/usr/bin/env python3
"""Exercise Watchdog Jobs in a disposable kind cluster, never the user's context."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

from kubernetes_chart import documents


KIND = os.environ.get("KIND", "kind")
KUBECTL = os.environ.get("KUBECTL", "kubectl")
IMAGE = os.environ.get("WATCHDOG_KUBERNETES_IMAGE", "watchdog:kubernetes-test")
NODE_IMAGE = os.environ.get(
    "KIND_NODE_IMAGE",
    "kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a",
)


class Integration:
    def __init__(self, directory):
        self.name = "watchdog-test-" + uuid.uuid4().hex[:10]
        self.context = "kind-" + self.name
        self.env = dict(os.environ, KUBECONFIG=str(Path(directory) / "kubeconfig"))
        repository, tag = IMAGE.rsplit(":", 1)
        self.values = {
            "image": {"repository": repository, "tag": tag, "pullPolicy": "Never"},
            "config": {
                "settings": {
                    "log_file": "/var/lib/watchdog/watchdog.log",
                    "lock_file": "/tmp/watchdog.lock",
                    "state_directory": "/var/lib/watchdog/state",
                    "default_timeout": 5,
                    "default_attempts": 1,
                    "default_retry_delay": 0,
                },
                "services": [
                    {
                        "name": "kubernetes-runtime",
                        "check": {"type": "command", "commands": [{"command": ["test", "!", "-S", "/var/run/docker.sock"]}]},
                    }
                ],
            },
            "schedule": {"suspend": True},
            "state": {"size": "64Mi"},
            "job": {"activeDeadlineSeconds": 120, "ttlSecondsAfterFinished": 300},
        }

    def run(self, arguments, data=None, check=True, timeout=240):
        result = subprocess.run(
            arguments,
            input=data,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            env=self.env,
            timeout=timeout,
            check=False,
        )
        if check and result.returncode:
            raise AssertionError(f'{" ".join(arguments)} failed:\n{result.stdout}\n{result.stderr}')
        return result

    def kubectl(self, *arguments, **kwargs):
        return self.run(
            [KUBECTL, "--context", self.context, "--namespace", "default", "--request-timeout=20s", *arguments],
            **kwargs,
        )

    def apply(self, items):
        self.kubectl("apply", "-f", "-", data=json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))

    def finish(self, name, expected=0, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            job = json.loads(self.kubectl("get", "job", name, "-o", "json").stdout)
            conditions = job.get("status", {}).get("conditions", [])
            if any(condition["type"] in ("Complete", "Failed") and condition["status"] == "True" for condition in conditions):
                break
            time.sleep(2)
        else:
            raise AssertionError(f"job {name} did not finish within {timeout}s")

        pods = json.loads(self.kubectl("get", "pods", "-l", f"job-name={name}", "-o", "json").stdout)["items"]
        statuses = [
            status.get("state", {}).get("terminated", {})
            for pod in pods
            for status in pod.get("status", {}).get("containerStatuses", [])
        ]
        if len(statuses) != 1 or statuses[0].get("exitCode") != expected:
            logs = self.kubectl("logs", "job/" + name, check=False).stdout
            raise AssertionError(f"{name}: expected exit {expected}, got {statuses}\n{logs}")
        logs = self.kubectl("logs", "job/" + name, check=False).stdout
        print(f"PASS {name} (exit {expected})", flush=True)
        return logs

    def inspector_job(self, name, arguments):
        return {
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": {"name": name},
            "spec": {
                "backoffLimit": 0,
                "template": {
                    "spec": {
                        "automountServiceAccountToken": False,
                        "restartPolicy": "Never",
                        "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001},
                        "containers": [
                            {
                                "name": "inspect",
                                "image": IMAGE,
                                "imagePullPolicy": "Never",
                                "command": ["test"],
                                "args": arguments,
                                "securityContext": {
                                    "allowPrivilegeEscalation": False,
                                    "readOnlyRootFilesystem": True,
                                    "capabilities": {"drop": ["ALL"]},
                                },
                                "volumeMounts": [{"name": "state", "mountPath": "/var/lib/watchdog", "readOnly": True}],
                            }
                        ],
                        "volumes": [{"name": "state", "persistentVolumeClaim": {"claimName": "watchdog-watchdog-state", "readOnly": True}}],
                    }
                },
            },
        }

    def test(self):
        print("Creating isolated cluster " + self.name, flush=True)
        result = self.run(
            [KIND, "create", "cluster", "--name", self.name, "--kubeconfig", self.env["KUBECONFIG"], "--image", NODE_IMAGE, "--wait", "180s"],
            timeout=600,
        )
        print(result.stderr, flush=True)
        self.run([KIND, "load", "docker-image", IMAGE, "--name", self.name], timeout=300)

        self.apply(documents(self.values))
        self.kubectl("create", "job", "watchdog-cycle", "--from=cronjob/watchdog-watchdog")
        self.finish("watchdog-cycle")
        self.apply([self.inspector_job("watchdog-state", ["-f", "/var/lib/watchdog/state/kubernetes-runtime.state"])])
        self.finish("watchdog-state")

        invalid = copy.deepcopy(self.values)
        invalid["config"] = {"settings": {"state_directory": "/var/lib/watchdog/state"}, "services": []}
        invalid["manual"] = {"enabled": True, "name": "invalid", "args": ["validate"]}
        self.apply(documents(invalid))
        logs = self.finish("watchdog-watchdog-invalid", expected=2)
        if "services" not in logs:
            raise AssertionError("invalid configuration did not identify services: " + logs)
        print("Watchdog Kubernetes integration passed: finite CronJob cycle, persistent state, no Docker socket, and invalid-config exit status.", flush=True)

    def diagnostics(self):
        print(self.kubectl("get", "pods,jobs,pvc,cronjob", "-o", "wide", check=False).stdout, flush=True)
        pods = self.kubectl("get", "pods", "-o", "json", check=False)
        if pods.returncode == 0:
            for pod in json.loads(pods.stdout).get("items", []):
                name = pod["metadata"]["name"]
                print(f"--- {name} ---\n" + self.kubectl("logs", name, check=False).stdout, flush=True)
        print(self.kubectl("get", "events", "--sort-by=.lastTimestamp", check=False).stdout, flush=True)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="watchdog-kubernetes-") as directory:
        test = Integration(directory)
        try:
            test.test()
        except Exception:
            test.diagnostics()
            raise
        finally:
            result = test.run([KIND, "delete", "cluster", "--name", test.name], check=False, timeout=180)
            print(result.stderr, flush=True)
            if result.returncode:
                raise RuntimeError("test cluster cleanup failed: " + test.name)


if __name__ == "__main__":
    main()
