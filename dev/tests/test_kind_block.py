"""Exercise the shared lifecycle without root or a Kubernetes cluster."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


DEV = Path(__file__).resolve().parents[1]
MOCK = r'''#!/bin/bash
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$MOCK_ROOT/calls"
case "$tool" in
  id) echo 1000 ;;
  sudo) [[ "${1:-}" != -n ]] || shift; exec "$@" ;;
  docker)
    case "$*" in
      'context inspect'*) echo "${MOCK_ENDPOINT:-unix:///var/run/docker.sock}" ;;
      *OperatingSystem*) echo Linux ;;
      *SecurityOptions*) echo "${MOCK_SECURITY:-[]}" ;;
      'ps -aq'*) [[ "${MOCK_NODES_REMAIN:-false}" != true ]] || echo leftover-node ;;
      'inspect'*) [[ "${MOCK_REGISTRY_EXISTS:-false}" == true ]] || exit 1 ;;
      *exec*) : ;;
    esac ;;
  podman)
    case "$*" in
      *Distribution*) echo "${MOCK_PODMAN_DISTRO:-fedora}" ;;
      *ps\ -aq*) [[ "${MOCK_NODES_REMAIN:-false}" != true ]] || echo leftover-node ;;
      'inspect'*) [[ "${MOCK_REGISTRY_EXISTS:-false}" == true ]] || exit 1 ;;
      *exec*) : ;;
    esac ;;
  losetup)
    case "$*" in
      *--find*) echo /dev/loop999 ;;
      *--associated*)
        [[ "${MOCK_LOOKUP_FAIL:-false}" != true ]] || exit 1
        echo /dev/loop999 ;;
      *--detach*) [[ "${MOCK_DETACH_FAIL:-false}" != true ]] || exit 1 ;;
    esac ;;
  kind)
    case "$1 ${2:-}" in
      'version '*) echo 'kind v0.33.0 go1.26.0 linux/amd64' ;;
      'get clusters') [[ ! -f "$MOCK_ROOT/cluster" ]] || cat "$MOCK_ROOT/cluster" ;;
      'get nodes') printf 'block-test-worker\nblock-test-worker2\n' ;;
      'create cluster')
        echo "$MEDIK8S_CLUSTER_NAME" > "$MOCK_ROOT/cluster"
        touch "$KUBECONFIG"
        [[ "${MOCK_CREATE_FAIL:-false}" != true ]] || exit 1 ;;
      'delete cluster') rm -f "$MOCK_ROOT/cluster" ;;
    esac ;;
  kubectl)
    case "$1 ${2:-}" in
      'cluster-info '*) exit 1 ;;
      'config current-context') echo "kind-$MEDIK8S_CLUSTER_NAME" ;;
      'get nodes')
        if [[ "$*" == *'-o name'* ]]; then
          printf 'node/block-test-worker\nnode/block-test-worker2\n'
        else
          printf 'block-test-worker\nblock-test-worker2\n'
        fi ;;
      'get node') echo node-role.kubernetes.io/worker ;;
    esac ;;
  go) : ;;
esac
'''


class KindBlockLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kind-block-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ["id", "sudo", "docker", "losetup", "kind", "kubectl", "go", "podman", "chown"]:
            path = self.bin / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = dict(os.environ)
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "KIND_HA", "KUBECONFIG"]:
            self.env.pop(key, None)
        self.env.update(
            PATH=f"{self.bin}:{os.environ['PATH']}", MOCK_ROOT=str(self.root),
            KIND_BLOCK_STATE_DIR=str(self.state), KIND_BLOCK_STORAGE="true",
            CONTAINER_TOOL="docker", KUBECTL="kubectl", SKIP_REGISTRY="true",
            MEDIK8S_CLUSTER_NAME="block-test",
        )

    def run_script(self, name, *args, success=True, **extra):
        result = subprocess.run(
            ["bash", str(DEV / name), *args], env=self.env | extra,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def setup_cluster(self, **extra):
        return self.run_script("setup.sh", "--skip-olm", "--skip-inotify-check", **extra)

    def calls(self):
        return (self.root / "calls").read_text()

    def test_setup_and_cleanup_share_one_device(self):
        self.setup_cluster()
        config = (self.state / "kind.yaml").read_text()
        self.assertEqual(config.count("hostPath: /dev/loop999"), 2)
        self.assertEqual(config.count("role: control-plane"), 1)
        self.assertEqual(config.count('medik8s.io/kind-block: "true"'), 2)
        self.assertIn(str(self.state / "kind.yaml"), self.calls())
        self.assertIn("modprobe softdog", self.calls())
        self.run_script("teardown.sh")
        self.assertLess(self.calls().index("kind delete cluster"), self.calls().index("losetup --detach"))
        self.assertIn("losetup --detach /dev/loop999", self.calls())
        self.assertNotIn("docker rm", self.calls())
        self.assertFalse((self.state / "block.img").exists())
        self.assertFalse((self.state / "owned").exists())
        self.assertTrue((self.state / "kind.yaml").exists())
        self.run_script("teardown.sh")

    def test_ha_preserves_three_control_planes(self):
        self.setup_cluster(KIND_HA="true")
        config = (self.state / "kind.yaml").read_text()
        self.assertEqual(config.count("role: control-plane"), 3)
        self.assertEqual(config.count("role: worker"), 2)

    def test_rejects_existing_cluster_and_preserves_device(self):
        self.setup_cluster()
        self.setup_cluster(success=False)
        self.assertEqual(sum(line.startswith("losetup --find") for line in self.calls().splitlines()), 1)
        self.assertTrue((self.state / "block.img").exists())

    def test_cleans_up_after_cluster_creation_failure(self):
        self.setup_cluster(success=False, MOCK_CREATE_FAIL="true")
        self.assertTrue((self.state / "owned").exists())
        self.run_script("teardown.sh")
        self.assertFalse((self.state / "block.img").exists())

    def test_rejects_podman_machine(self):
        self.setup_cluster(success=False, CONTAINER_TOOL="podman", MOCK_PODMAN_DISTRO="Podman Machine")
        self.assertNotIn(" --find", self.calls())

    def test_refuses_detach_if_nodes_remain(self):
        self.setup_cluster()
        self.run_script("teardown.sh", success=False, MOCK_NODES_REMAIN="true")
        self.assertNotIn("losetup --detach", self.calls())
        self.assertTrue((self.state / "block.img").exists())

    def test_device_errors_preserve_state_for_retry(self):
        for fault in ["MOCK_LOOKUP_FAIL", "MOCK_DETACH_FAIL"]:
            with self.subTest(fault=fault):
                if not (self.state / "owned").exists():
                    self.setup_cluster()
                self.run_script("teardown.sh", success=False, **{fault: "true"})
                self.assertTrue((self.state / "block.img").exists())
                self.assertTrue((self.state / "owned").exists())
        self.run_script("teardown.sh")

    def test_unowned_teardown_does_not_delete_cluster(self):
        (self.root / "cluster").write_text("block-test\n")
        self.run_script("teardown.sh")
        self.assertTrue((self.root / "cluster").exists())

    def test_wrong_cluster_cannot_use_state(self):
        self.setup_cluster()
        self.run_script("teardown.sh", success=False, MEDIK8S_CLUSTER_NAME="another-cluster")
        self.assertNotIn("kind delete cluster", self.calls())

    def test_rejects_external_remote_and_rootless_setups(self):
        self.run_script("setup.sh", "--skip-kind", success=False)
        self.setup_cluster(success=False, MOCK_ENDPOINT="ssh://other-host")
        self.setup_cluster(success=False, MOCK_SECURITY='["rootless"]')
        self.assertNotIn("losetup --find", self.calls())

    def test_default_setup_does_not_touch_block_storage(self):
        # Normal mode keeps the existing config and watchdog behavior.
        self.state.mkdir()
        self.setup_cluster(KIND_BLOCK_STORAGE="false", KUBECONFIG=str(self.state / "normal-kubeconfig"))
        self.assertIn(f"--config {DEV / 'kind-config.yaml'}", self.calls())
        self.assertNotIn("losetup", self.calls())
        self.assertNotIn(str(self.state / "kind.yaml"), self.calls())
        self.assertIn("modprobe softdog", self.calls())


if __name__ == "__main__":
    unittest.main()
