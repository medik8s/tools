"""Exercise Machine deletion boundaries without Docker or a Kubernetes cluster."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("kind_mdr", Path(__file__).resolve().parents[1] / "kind_mdr.py")
mdr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mdr)


class MachineLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)
        self.entry = {"name": "test-worker", "uid": "node-old", "machine_uid": "machine-old", "container_id": "container-old"}
        self.fixture = {"cluster": "test", "owner_uid": "owner", "workers": [self.entry],
                        "control_plane": {"name": "test-control-plane", "uid": "cp"},
                        "spare": {"name": "test-worker3", "uid": "spare-old", "container_id": "spare-container"}}
        self.machine = mdr.machine_object("test-worker", "test", "owner")
        self.machine["metadata"].update(uid="machine-old", resourceVersion="5")
        self.machine["metadata"]["finalizers"].append("another-controller/finalizer")
        self.calls = []
        self.removed = False
        self.node_removed = False
        self.machine_removed = False
        mdr.save(self.state / "fixture.json", self.fixture)

    def fake_docker(self, *args):
        self.calls.append(("docker", args))
        if args[0] == "inspect":
            spare = args[1] == "test-worker3"
            return json.dumps([{"Id": "spare-container" if spare else "container-old",
                                "State": {"Running": not spare},
                                "Config": {"Labels": {"io.x-k8s.kind.cluster": "test", "io.x-k8s.kind.role": "worker"}}}])
        if args[0] == "rm":
            self.removed = True
        if args[0] == "ps":
            return "" if self.removed else "container-old"
        return ""

    def fake_get(self, resource, name, namespace=None):
        if resource == mdr.MACHINES:
            return None if self.machine_removed else copy.deepcopy(self.machine)
        if name == "test-control-plane":
            return {"metadata": {"uid": "cp"}}
        if name == "test-worker3":
            return None
        return None if self.node_removed else {"metadata": {"uid": "node-old"}}

    def fake_kube(self, *args, data=None):
        self.calls.append(("kube", args, data))
        if args[0] == "delete":
            self.assertTrue(self.removed)
            self.assertEqual(json.loads(data)["preconditions"]["uid"], "node-old")
            self.node_removed = True
        if args[0] == "patch":
            self.assertTrue(self.node_removed)
            ops = json.loads(args[-1])
            self.assertEqual(ops[0], {"op": "test", "path": "/metadata/uid", "value": "machine-old"})
            self.assertEqual(ops[-1]["value"], ["another-controller/finalizer"])
            self.machine_removed = True
        return ""

    def mocked_io(self):
        for name, implementation in [("docker", self.fake_docker), ("get", self.fake_get), ("kube", self.fake_kube)]:
            mock = patch.object(mdr, name, side_effect=implementation)
            mock.start()
            self.addCleanup(mock.stop)

    def test_no_deletion_request_causes_no_action(self):
        self.mocked_io()
        self.assertIsNone(mdr.pending_machine(self.fixture))
        self.assertEqual(self.calls, [])

    def test_unrelated_or_changed_machine_is_rejected(self):
        self.mocked_io()
        for field, value in [("uid", "foreign"), ("labels", {}), ("ownerReferences", []), ("finalizers", [])]:
            with self.subTest(field=field):
                original = self.machine["metadata"][field]
                self.machine["metadata"][field] = value
                with self.assertRaises(RuntimeError):
                    mdr.pending_machine(self.fixture)
                self.machine["metadata"][field] = original
        self.assertEqual(self.calls, [])

    def test_rejects_foreign_control_plane_or_recreated_container(self):
        for cluster, role, identity in [("other", "worker", "container-old"),
                                        ("test", "control-plane", "container-old"),
                                        ("test", "worker", "different")]:
            info = [{"Id": identity, "Config": {"Labels": {
                "io.x-k8s.kind.cluster": cluster, "io.x-k8s.kind.role": role}}}]
            with patch.object(mdr, "docker", return_value=json.dumps(info)):
                with self.assertRaises(RuntimeError):
                    mdr.inspect_worker("test-worker", "test", "container-old")

    def test_deletion_order_and_preserves_other_finalizers(self):
        self.mocked_io()
        mdr.remove_machine(self.entry, self.machine, self.fixture)
        self.assertTrue(self.machine_removed)
        actions = [(c[0], c[1][0]) for c in self.calls]
        self.assertLess(actions.index(("docker", "rm")), actions.index(("kube", "delete")))
        self.assertLess(actions.index(("kube", "delete")), actions.index(("kube", "patch")))

    def test_container_removal_failure_never_finalizes(self):
        self.mocked_io()
        def failed_remove(*args):
            if args[0] == "rm":
                raise RuntimeError("injected Docker failure")
            return self.fake_docker(*args)
        with patch.object(mdr, "docker", side_effect=failed_remove):
            with self.assertRaisesRegex(RuntimeError, "injected"):
                mdr.remove_machine(self.entry, self.machine, self.fixture)
        self.assertFalse(self.node_removed)
        self.assertFalse(self.machine_removed)

    def test_changed_node_is_not_deleted(self):
        self.mocked_io()
        with patch.object(mdr, "get", return_value={"metadata": {"uid": "new-node"}}):
            with self.assertRaisesRegex(RuntimeError, "identity"):
                mdr.remove_machine(self.entry, self.machine, self.fixture)
        self.assertFalse(self.removed)

    def test_missing_or_stale_gate_cannot_start_spare(self):
        self.mocked_io()
        self.machine["metadata"]["deletionTimestamp"] = "2026-09-28T00:00:00Z"
        (self.state / "replace-stale-uid").touch()
        def no_wait(message, predicate, timeout):
            result = predicate()
            if result:
                return result
            raise RuntimeError("Timed out: " + message)
        with patch.object(mdr, "wait_for", side_effect=no_wait):
            with self.assertRaisesRegex(RuntimeError, "replacement release"):
                mdr.watch("test", self.state)
        self.assertTrue(self.machine_removed)
        self.assertFalse(any(c[0] == "docker" and c[1][0] == "start" for c in self.calls))
        self.assertFalse((self.state / "complete.json").exists())

    def test_not_ready_and_stale_cni_subnet_are_not_published(self):
        node = {"spec": {"podCIDR": "10.244.5.0/24"},
                "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        config = {"plugins": [{"ipam": {"ranges": [[{"subnet": "10.244.3.0/24"}]]}}, {"type": "portmap"}]}
        with patch.object(mdr, "get", return_value=node), patch.object(mdr, "docker", return_value=json.dumps(config)):
            self.assertFalse(mdr.cni_ready("spare"))
        config["plugins"][0]["ipam"]["ranges"][0][0]["subnet"] = "10.244.5.0/24"
        with patch.object(mdr, "get", return_value=node), patch.object(mdr, "docker", return_value=json.dumps(config)):
            self.assertEqual(mdr.cni_ready("spare"), node)

    def test_matching_gate_replaces_only_after_deletion_and_network_check(self):
        self.mocked_io()
        self.machine["metadata"]["deletionTimestamp"] = "2026-09-28T00:00:00Z"
        (self.state / "replace-machine-old").touch()
        replacement = {"metadata": {"name": "test-worker3", "uid": "spare-new"}}
        def create_machine(obj):
            self.assertTrue(self.machine_removed)
            self.assertEqual(obj["metadata"]["name"], "test-worker3-replacement")
            self.calls.append(("replacement", "create"))
        def network(*args):
            self.calls.append(("replacement", "network"))
        def publish(*args):
            self.assertIn(("replacement", "network"), self.calls)
            self.calls.append(("replacement", "publish"))
        with patch.object(mdr, "create", side_effect=create_machine), \
                patch.object(mdr, "cni_ready", return_value=replacement), \
                patch.object(mdr, "verify_network", side_effect=network), \
                patch.object(mdr, "link_node", side_effect=publish):
            mdr.watch("test", self.state)
        self.assertLess(self.calls.index(("replacement", "create")),
                        self.calls.index(("docker", ("start", "spare-container"))))
        self.assertTrue((self.state / "complete.json").exists())

    def test_node_delete_failure_preserves_machine_finalizer(self):
        self.mocked_io()
        with patch.object(mdr, "delete_node", side_effect=RuntimeError("Node delete failed")):
            with self.assertRaisesRegex(RuntimeError, "Node delete failed"):
                mdr.remove_machine(self.entry, self.machine, self.fixture)
        self.assertTrue(self.removed)
        self.assertFalse(self.machine_removed)


if __name__ == "__main__":
    unittest.main()
