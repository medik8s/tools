"""Validate MDR setup and explicitly test replacement on a prepared Kind cluster."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


DEV = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DEV))
import kind_mdr


MOCK = r'''#!/bin/bash
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$MOCK_ROOT/calls"
case "$tool" in
  kind)
    case "$1 ${2:-}" in
      'version '*) echo 'kind v0.33.0 go1.26.0 linux/amd64' ;;
      'get nodes') echo mdr-test-worker ;;
    esac ;;
  kubectl)
    case "$1 ${2:-}" in
      'cluster-info '*) exit 1 ;;
      'get nodes') echo mdr-test-worker ;;
      'get node') echo node-role.kubernetes.io/worker ;;
    esac ;;
  python3) exit "${MOCK_PREPARE_STATUS:-0}" ;;
esac
'''


class MDRSetup(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="kind-mdr-setup-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("kind", "kubectl", "docker", "python3", "go"):
            command = self.bin / name
            command.write_text(MOCK)
            command.chmod(0o755)
        self.crds = self.root / "crds"
        self.crds.mkdir()
        for resource in ("machines", "machinesets"):
            (self.crds / f"0000_10_machine-api_01_{resource}-Default.crd.yaml").touch()
        self.env = dict(os.environ) | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "MOCK_ROOT": str(self.root), "CONTAINER_TOOL": "docker", "KUBECTL": "kubectl",
            "KUBECONFIG": str(self.root / "kubeconfig"), "MEDIK8S_CLUSTER_NAME": "mdr-test",
            "KIND_BLOCK_STORAGE": "false", "KIND_HA": "false", "SKIP_REGISTRY": "true",
            "SETUP_MDR_MOCK": "false", "MDR_CRD_DIR": str(self.crds),
            "SETUP_DOCKER_SOCKET": "false", "SETUP_NFS_RWX": "false",
            "SETUP_NULL_DEVICE_WATCHDOG": "false",
        }

    def setup_cluster(self, *args, **extra):
        return subprocess.run(
            ["bash", str(DEV / "setup.sh"), "--skip-olm", "--skip-inotify-check", *args],
            env=self.env | extra, text=True, capture_output=True,
        )

    def calls(self):
        path = self.root / "calls"
        return path.read_text() if path.exists() else ""

    def test_mock_is_opt_in(self):
        result = self.setup_cluster(MDR_CRD_DIR="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("kind_mdr.py", self.calls())

    def test_prepares_fixture_after_node_readiness(self):
        result = self.setup_cluster(SETUP_MDR_MOCK="true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"kind_mdr.py prepare --name mdr-test --crd-dir {self.crds}", self.calls())
        self.assertLess(self.calls().index("wait --for=condition=Ready node"), self.calls().index("kind_mdr.py"))

    def test_prepare_failure_fails_setup(self):
        result = self.setup_cluster(SETUP_MDR_MOCK="true", MOCK_PREPARE_STATUS="23")
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)

    def test_rejects_external_or_ha_before_cluster_commands(self):
        for option in ("--skip-kind", "--ha"):
            with self.subTest(option=option):
                result = self.setup_cluster(option, SETUP_MDR_MOCK="true")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires a Kind cluster with one control plane", result.stderr)
                self.assertEqual(self.calls(), "")

    def test_rejects_missing_crds_before_cluster_commands(self):
        for directory in ("", str(self.crds / "missing")):
            with self.subTest(directory=directory):
                result = self.setup_cluster(SETUP_MDR_MOCK="true", MDR_CRD_DIR=directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires MDR_CRD_DIR", result.stderr)
                self.assertEqual(self.calls(), "")
        (self.crds / "0000_10_machine-api_01_machinesets-Default.crd.yaml").unlink()
        result = self.setup_cluster(SETUP_MDR_MOCK="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), "")


class MDRCluster(unittest.TestCase):
    def test_worker_replacement(self):
        cluster = os.environ["MEDIK8S_CLUSTER_NAME"]
        self.assertEqual(kind_mdr.kube("config", "current-context").strip(), f"kind-{cluster}")
        kind_mdr.kube("wait", "--for=condition=Established",
                      "crd/machines.machine.openshift.io", "crd/machinesets.machine.openshift.io", "--timeout=60s")
        kind_mdr.kube("wait", "--for=condition=Ready", "node", "--all", "--timeout=120s")
        kind_mdr.kube("wait", "--for=condition=Available", "deployment", "--all",
                      "-n", "cert-manager", "--timeout=120s")
        kind_mdr.kube("wait", "--for=condition=Available", "deployment/olm-operator",
                      "-n", "olm", "--timeout=120s")

        fixture = kind_mdr.discover(cluster)
        victim = fixture["workers"][0]
        owner = kind_mdr.get("machinesets.machine.openshift.io", kind_mdr.OWNER, kind_mdr.NS)
        replicas = owner["spec"]["replicas"]
        self.assertEqual(len(fixture["workers"]), 3, fixture)

        kind_mdr.kube("delete", kind_mdr.MACHINES, victim["name"], "-n", kind_mdr.NS, "--wait=false")
        subprocess.run([
            str(DEV / "kind-reboot-watcher.sh"), "--mode", "mdr", "--once", "--name", cluster,
        ], check=True)

        self.assertIsNone(kind_mdr.get(kind_mdr.MACHINES, victim["name"], kind_mdr.NS))
        self.assertIsNone(kind_mdr.get("node", victim["name"]))
        self.assertFalse(kind_mdr.container("ps", "-aq", "--no-trunc", "--filter",
                                            f"id={victim['container_id']}").strip())
        replacement = kind_mdr.discover(cluster)
        new_worker = next(w for w in replacement["workers"] if w["name"] == victim["name"] + "-replacement")
        self.assertNotEqual(new_worker["uid"], victim["uid"])
        self.assertNotEqual(new_worker["machine_uid"], victim["machine_uid"])
        self.assertNotEqual(new_worker["container_id"], victim["container_id"])
        self.assertEqual(replacement["owner_uid"], fixture["owner_uid"])
        self.assertEqual(len(replacement["workers"]), replicas)
        self.assertEqual(kind_mdr.get("machinesets.machine.openshift.io", kind_mdr.OWNER,
                                      kind_mdr.NS)["spec"]["replicas"], replicas)
        for worker in fixture["workers"][1:]:
            self.assertIn(worker, replacement["workers"])
        self.assertEqual(kind_mdr.get("pod", "replacement-network", kind_mdr.NS)["status"]["phase"], "Succeeded")
        print("Machine deletion produced a fresh Ready worker with working pod networking.")
        print(json.dumps(replacement, indent=2))


def load_tests(loader, tests, pattern):
    # Cluster replacement must be selected explicitly; discovery runs without a cluster.
    return loader.loadTestsFromTestCase(MDRSetup)


if __name__ == "__main__":
    unittest.main()
