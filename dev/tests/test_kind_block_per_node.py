"""Exercise private device ownership and retries without host devices."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


DEV = Path(__file__).resolve().parents[1]
MODULE_SPEC = importlib.util.spec_from_file_location("kind_block_per_node", DEV / "kind_block_per_node.py")
PRIVATE = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(PRIVATE)


class HostModel:
    def __init__(self):
        self.fixture = None
        self.calls = []
        self.loops = {}
        self.mappings = {}
        self.pvs = {}
        self.pods = {}
        self.pvcs = {}
        self.fail = set()
        self.deferred = set()
        self.nodes_exist = False
        self.patch_mode = "bind"
        self.patch_count = 0
        self.patch_observations = []

    def reject(self, condition):
        if condition in self.fail:
            raise PRIVATE.FixtureError(f"Injected {condition} failure")

    def node(self, worker):
        return {"metadata": {"name": worker["node"], "uid": f"node-{worker['index']}", "labels": {
            PRIVATE.LABEL: self.fixture.state["id"], "kubernetes.io/hostname": worker["node"],
        }}}

    def container(self, worker):
        return {"Id": f"container-{worker['index']}", "Name": "/" + worker["node"],
                "Config": {"Labels": {"io.x-k8s.kind.cluster": self.fixture.cluster}},
                "Mounts": [{"Source": f"/dev/mapper/{worker['map']}", "Destination": PRIVATE.DEVICE}]}

    def __call__(self, argv, timeout=10, input=None, check=True):
        args = list(argv)
        if args[:2] == ["sudo", "-n"]:
            args = args[2:]
        self.calls.append((args, timeout))
        tool, rest = args[0], args[1:]
        if tool == "python3" and Path(rest[0]).name == "kind_block_references.py":
            self.reject("references")
            return ""
        if tool == "truncate":
            with open(rest[-1], "wb") as image:
                image.truncate(64 * 1024 * 1024)
            self.reject(f"allocate-image:{Path(rest[-1]).stem}")
            return ""
        if tool == "losetup":
            if rest[0] == "--find":
                index = int(Path(rest[-1]).stem)
                self.loops[rest[-1]] = {"name": f"/dev/loop{100 + index}", "back-file": rest[-1],
                                        "dio": 1, "maj:min": f"7:{100 + index}"}
                self.reject(f"allocate-loop:{index}")
                return self.loops[rest[-1]]["name"]
            if rest[0] == "--associated":
                image = rest[1]
                self.reject(f"loop-query:{Path(image).stem}")
                loop = self.loops.get(image)
                return json.dumps({"loopdevices": [loop] if loop else []})
            if rest[0] == "--detach":
                image = next(path for path, loop in self.loops.items() if loop["name"] == rest[1])
                index = int(Path(image).stem)
                self.reject(f"detach:{index}")
                if index not in self.deferred:
                    del self.loops[image]
                return ""
        if tool == "blockdev":
            self.reject(f"allocate-size:{int(rest[-1].removeprefix('/dev/loop')) - 100}")
            return "131072"
        if tool == "dmsetup":
            action = rest[0]
            if action == "targets":
                return "linear v1.0.0\nerror v1.0.0"
            if action == "info":
                self.reject("mapping-query")
                if not self.mappings:
                    return "No devices found"
                return "\n".join(f"{name}|{value['uuid']}|{value['open']}|"
                                 f"{'suspended' if value['suspended'] else 'active'}"
                                 for name, value in self.mappings.items())
            if action == "create":
                name = rest[1]
                self.mappings[name] = {"uuid": rest[rest.index("--uuid") + 1], "open": 0,
                                       "suspended": False, "table": rest[rest.index("--table") + 1]}
                self.reject(f"allocate-map:{name.rsplit('-', 1)[-1]}")
                return ""
            if action == "table":
                return self.mappings[rest[1]]["table"]
            if action == "suspend":
                self.mappings[rest[-1]]["suspended"] = True
                return ""
            if action == "reload":
                self.reject("reload")
                self.mappings[rest[1]]["pending"] = rest[rest.index("--table") + 1]
                return ""
            if action == "resume":
                mapping = self.mappings[rest[-1]]
                mapping["table"] = mapping.pop("pending", mapping["table"])
                mapping["suspended"] = False
                return ""
            if action == "remove":
                self.reject(f"remove:{rest[1].rsplit('-', 1)[-1]}")
                del self.mappings[rest[1]]
                return ""
        if tool == "kind":
            if rest[:2] == ["get", "clusters"]:
                return self.fixture.cluster if self.nodes_exist else ""
            if rest[:2] == ["delete", "cluster"]:
                self.reject("kind-delete")
                self.nodes_exist = False
                return ""
        if tool == "docker":
            if rest[:2] == ["ps", "-aq"]:
                self.reject("engine-query")
                return "\n".join(w["node"] for w in self.fixture.state["workers"]) if self.nodes_exist else ""
            if rest[0] == "inspect":
                worker = next(w for w in self.fixture.state["workers"]
                              if rest[1] in (w["node"], f"container-{w['index']}"))
                return json.dumps([self.container(worker)])
            if rest[0] == "exec":
                if "crictl" in rest:
                    return json.dumps({"containers": []})
                return ""
        if tool == "kubectl":
            rest = rest[3:]
            if rest[:2] == ["config", "current-context"]:
                return f"kind-{self.fixture.cluster}"
            if rest[:2] == ["get", "nodes"]:
                return json.dumps({"items": [self.node(w) for w in self.fixture.state["workers"]]})
            if rest[0] == "get":
                kind, name = rest[1:3]
                namespace = rest[rest.index("-n") + 1] if "-n" in rest else None
                if kind == "node":
                    return json.dumps(self.node(next(w for w in self.fixture.state["workers"] if w["node"] == name)))
                objects = {"pv": self.pvs, "pod": self.pods, "pvc": self.pvcs}[kind]
                value = objects.get((namespace, name) if namespace else name)
                self.reject(f"get:{kind}:{name}")
                return json.dumps(value) if value else ""
            if rest[0] == "create":
                manifest = json.loads(Path(rest[2]).read_text())
                for item in manifest["items"]:
                    if item["kind"] == "PersistentVolume":
                        item["metadata"].update(uid="pv-" + item["metadata"]["name"], resourceVersion="10")
                        item["status"] = {"phase": "Available"}
                        self.pvs[item["metadata"]["name"]] = item
                self.reject("install")
                return ""
            if rest[0] == "delete":
                return ""
            if rest[0] == "patch":
                self.patch_count += 1
                operation = json.loads((self.fixture.directory / "reclaim-1.json").read_text())
                self.patch_observations.append(operation)
                patch = json.loads(rest[rest.index("-p") + 1])
                pv = self.pvs[rest[2]]
                if self.patch_mode == "conflict" and self.patch_count == 1:
                    pv["metadata"]["resourceVersion"] = "11"
                    raise PRIVATE.FixtureError("Conflict")
                for test in patch[:-1]:
                    value = pv
                    for part in test["path"].strip("/").split("/"):
                        value = value[part]
                    if value != test["value"]:
                        raise PRIVATE.FixtureError("Conditional patch failed")
                del pv["spec"]["claimRef"]
                pv["status"]["phase"] = "Available"
                pv["metadata"]["resourceVersion"] = "12"
                if self.patch_mode in ("bind", "lost-response", "conflict"):
                    replacement = operation["replacement"]
                    pv["spec"]["claimRef"] = {"uid": replacement["pvc_uid"], "name": replacement["pvc"],
                                              "namespace": replacement["namespace"]}
                    pv["status"]["phase"] = "Bound"
                    pvc = self.pvcs[(replacement["namespace"], replacement["pvc"])]
                    pvc["spec"]["volumeName"] = pv["metadata"]["name"]
                    pvc["status"]["phase"] = "Bound"
                if self.patch_mode == "lost-unreadable":
                    self.fail.add(f"get:pv:{pv['metadata']['name']}")
                    raise PRIVATE.FixtureError("Patch response and follow-up read were lost")
                if self.patch_mode == "lost-response":
                    raise PRIVATE.FixtureError("Patch response was lost")
                return ""
        raise AssertionError(f"Unexpected mocked command: {args}")


class PrivateFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kind-private-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        environment = {"PATH": os.environ.get("PATH", ""), "MEDIK8S_CLUSTER_NAME": "private-test",
                       "CONTAINER_TOOL": "docker", "KUBECTL": "kubectl"}
        self.environ = mock.patch.dict(os.environ, environment, clear=True)
        self.environ.start()
        self.addCleanup(self.environ.stop)
        self.host = HostModel()
        self.fixture = PRIVATE.Fixture(self.root / "state", runner=self.host)
        self.host.fixture = self.fixture
        self.fixture.directory.mkdir()
        self.fixture.endpoint = "unix:///var/run/docker.sock"
        self.fixture.lease = self.root / "lease"
        self.fixture.lease.mkdir()

    def allocate(self, workers=None, ha=False):
        if workers is not None:
            os.environ["KIND_BLOCK_WORKERS"] = str(workers)
        if ha:
            os.environ["KIND_HA"] = "true"
        self.fixture.allocate()
        return self.fixture.state["workers"]

    def ready(self):
        self.allocate()
        self.host.nodes_exist = True
        with mock.patch("builtins.print"):
            self.fixture.install()
        return self.fixture.state["workers"]

    def state(self):
        return json.loads((self.fixture.directory / "fixture.json").read_text())

    def operation(self):
        return json.loads((self.fixture.directory / "reclaim-1.json").read_text())

    def changes(self, tool, action):
        return [args for args, _ in self.host.calls if args[:2] == [tool, action]]

    def consumer(self, name, uid, bound=False):
        worker = self.fixture.state["workers"][0]
        claim_spec = {"storageClassName": PRIVATE.STORAGE_CLASS, "volumeMode": "Block",
                      "accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "10Mi"}}}
        pod = {"metadata": {"name": name, "uid": uid, "labels": {PRIVATE.LABEL: self.fixture.state["id"]}},
               "spec": {"containers": [{"name": "probe", "volumeDevices": [{"name": "probe", "devicePath": "/dev/probe"}]}],
                        "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {
                            "nodeSelectorTerms": [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In",
                                                                         "values": [worker["hostname"]]}]}]}}},
                        "volumes": [{"name": "probe", "ephemeral": {"volumeClaimTemplate": {"spec": claim_spec}}}]}}
        pvc = {"metadata": {"name": name + "-probe", "uid": "claim-" + uid,
                            "labels": {PRIVATE.LABEL: self.fixture.state["id"]}, "ownerReferences": [{
                                "apiVersion": "v1", "kind": "Pod", "name": name, "uid": uid,
                                "controller": True, "blockOwnerDeletion": True}]},
               "spec": json.loads(json.dumps(claim_spec)), "status": {"phase": "Bound" if bound else "Pending"}}
        if bound:
            pvc["spec"]["volumeName"] = worker["pv"]
        self.host.pods[("test", name)] = pod
        self.host.pvcs[("test", name + "-probe")] = pvc
        return pod, pvc

    def prepare(self):
        worker = self.ready()[0]
        pod, pvc = self.consumer("original", "pod-original", bound=True)
        pv = self.host.pvs[worker["pv"]]
        pv["spec"]["claimRef"] = {"uid": pvc["metadata"]["uid"], "name": "original-probe", "namespace": "test"}
        pv["status"]["phase"] = "Bound"
        self.fixture.reclaim(worker["node"], "test", "original", "prepare")
        return worker, pod, pvc, pv

    def replacement(self, name="replacement", uid="pod-replacement"):
        self.host.pods.pop(("test", "original"), None)
        self.host.pvcs.pop(("test", "original-probe"), None)
        self.host.pvs[self.fixture.state["workers"][0]["pv"]]["status"]["phase"] = "Released"
        return self.consumer(name, uid)

    def expire_pause(self):
        raise PRIVATE.FixtureError("Test action deadline expired")

    def test_allocates_distinct_worker_devices_and_keeps_control_planes_unmapped(self):
        workers = self.allocate()
        self.assertEqual(len(workers), 3)
        for key in ["image", "loop", "map", "uuid", "pv"]:
            self.assertEqual(len({worker[key] for worker in workers}), 3, key)
        config = json.loads((self.fixture.directory / "kind.yaml").read_text())
        control_planes = [node for node in config["nodes"] if node["role"] == "control-plane"]
        worker_nodes = [node for node in config["nodes"] if node["role"] == "worker"]
        self.assertEqual(len(control_planes), 1)
        self.assertEqual(len(worker_nodes), 3)
        self.assertTrue(all("extraMounts" not in node for node in control_planes))
        for node, worker in zip(worker_nodes, workers):
            self.assertEqual(node["extraMounts"], [{"hostPath": "/dev/mapper/" + worker["map"],
                                                   "containerPath": PRIVATE.DEVICE}])

    def test_ha_preserves_requested_five_workers(self):
        self.allocate(workers=5, ha=True)
        nodes = json.loads((self.fixture.directory / "kind.yaml").read_text())["nodes"]
        self.assertEqual(sum(node["role"] == "worker" for node in nodes), 5)
        self.assertEqual(sum(node["role"] == "control-plane" for node in nodes), 3)

    def test_rejects_existing_cluster_before_allocating_devices(self):
        self.host.nodes_exist = True
        with self.assertRaisesRegex(PRIVATE.FixtureError, "already exists"):
            self.fixture.allocate()
        self.assertFalse(self.host.loops)
        self.assertFalse((self.fixture.directory / "owned").exists())

    def test_uncertain_loop_allocation_remains_available_for_cleanup(self):
        self.host.fail.add("allocate-loop:2")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "allocate-loop:2"):
            self.fixture.allocate()
        workers = self.state()["workers"]
        self.assertEqual(len(workers), 2)
        self.assertNotIn("loop", workers[1])
        self.assertIn(workers[1]["image"], self.host.loops)
        self.fixture.teardown()
        self.assertEqual(self.state()["phase"], "Cleaned")
        self.assertFalse(self.host.loops)
        self.assertFalse(self.host.mappings)

    def test_uncertain_mapping_creation_remains_available_for_cleanup(self):
        self.host.fail.add("allocate-map:2")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "allocate-map:2"):
            self.fixture.allocate()
        self.assertEqual(len(self.host.mappings), 2)
        self.fixture.teardown()
        self.assertFalse(self.host.mappings)
        self.assertFalse(self.host.loops)

    def test_failures_at_each_allocation_stage_allow_complete_cleanup(self):
        for stage in ["image", "loop", "size", "map"]:
            for index in range(1, 4):
                condition = f"allocate-{stage}:{index}"
                with self.subTest(condition=condition):
                    self.host.fail = {condition}
                    with self.assertRaisesRegex(PRIVATE.FixtureError, condition):
                        self.fixture.allocate()
                    self.assertEqual(len(self.state()["workers"]), index)
                    self.fixture.teardown()
                    self.assertEqual(self.state()["phase"], "Cleaned")
                    self.assertFalse(self.host.loops)
                    self.assertFalse(self.host.mappings)

    def test_setup_failure_cleans_allocated_resources(self):
        def failed_setup(*args, **kwargs):
            self.allocate()
            self.host.nodes_exist = True
            process = mock.Mock()
            process.wait.return_value = 1
            process.poll.return_value = 1
            return process

        with mock.patch.object(PRIVATE.subprocess, "Popen", side_effect=failed_setup):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "setup failed"):
                self.fixture.setup([])
        self.assertEqual(self.state()["phase"], "Cleaned")
        self.assertFalse(self.host.nodes_exist)
        self.assertFalse(self.host.loops)

    def test_setup_interruption_cleans_allocated_resources(self):
        def interrupted_setup(*args, **kwargs):
            self.allocate()
            self.host.nodes_exist = True
            process = mock.Mock(pid=12345)
            process.wait.side_effect = [KeyboardInterrupt(), 0]
            process.poll.return_value = None
            return process

        with mock.patch.object(PRIVATE.subprocess, "Popen", side_effect=interrupted_setup):
            with mock.patch.object(PRIVATE.os, "killpg") as kill:
                with self.assertRaises(KeyboardInterrupt):
                    self.fixture.setup([])
                kill.assert_called_once_with(12345, PRIVATE.signal.SIGTERM)
        self.assertEqual(self.state()["phase"], "Cleaned")
        self.assertFalse(self.host.nodes_exist)
        self.assertFalse(self.host.loops)

    def test_install_creates_exact_node_bound_retain_block_pvs(self):
        workers = self.ready()
        self.assertEqual(self.state()["phase"], "Ready")
        self.assertEqual(len(self.host.pvs), 3)
        for worker in workers:
            pv = self.host.pvs[worker["pv"]]
            self.assertEqual(pv["metadata"]["uid"], worker["pv_uid"])
            self.assertEqual(pv["spec"]["volumeMode"], "Block")
            self.assertEqual(pv["spec"]["accessModes"], ["ReadWriteOnce"])
            self.assertEqual(pv["spec"]["persistentVolumeReclaimPolicy"], "Retain")
            self.assertEqual(pv["spec"]["nodeAffinity"]["required"]["nodeSelectorTerms"], [{
                "matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": [worker["node"]]}]}])

    def test_failed_pv_install_keeps_device_records_for_cleanup(self):
        self.allocate()
        self.host.nodes_exist = True
        self.host.fail.add("install")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "install"):
            self.fixture.install()
        self.assertTrue((self.fixture.directory / "owned").exists())
        self.fixture.teardown()
        self.assertFalse(self.host.nodes_exist)
        self.assertFalse(self.host.loops)

    def test_error_fault_changes_only_selected_mapping(self):
        workers = self.ready()
        originals = {name: value["table"] for name, value in self.host.mappings.items()}
        self.fixture.fault(workers[0]["node"], "error")
        self.assertEqual(self.host.mappings[workers[0]["map"]]["table"], "0 131072 error")
        for worker in workers[1:]:
            self.assertEqual(self.host.mappings[worker["map"]]["table"], originals[worker["map"]])
            self.assertFalse(self.host.mappings[worker["map"]]["suspended"])
        self.fixture.fault(workers[0]["node"], "restore")
        self.assertEqual(self.host.mappings[workers[0]["map"]]["table"], originals[workers[0]["map"]])

    def test_hang_is_recorded_and_restored_before_nodes_are_removed(self):
        workers = self.ready()
        self.fixture.fault(workers[0]["node"], "hang")
        self.assertTrue(self.host.mappings[workers[0]["map"]]["suspended"])
        self.assertEqual(self.state()["workers"][0]["fault_observed"], "hang")
        self.host.calls.clear()
        self.fixture.teardown()
        commands = [args for args, _ in self.host.calls]
        resume = next(i for i, args in enumerate(commands) if args[:2] == ["dmsetup", "resume"])
        node_delete = next(i for i, args in enumerate(commands) if args[:3] == ["kind", "delete", "cluster"])
        mapping_remove = next(i for i, args in enumerate(commands) if args[:2] == ["dmsetup", "remove"])
        detach = next(i for i, args in enumerate(commands) if args[:2] == ["losetup", "--detach"])
        self.assertLess(resume, node_delete)
        self.assertLess(node_delete, mapping_remove)
        self.assertLess(mapping_remove, detach)
        self.assertTrue(all(timeout <= 10 for args, timeout in self.host.calls if args[0] == "dmsetup"))

    def test_interrupted_fault_records_intent_and_cleanup_restores_it(self):
        worker = self.ready()[0]
        self.host.fail.add("reload")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "reload"):
            self.fixture.fault(worker["node"], "error")
        self.assertEqual(self.state()["workers"][0]["fault"], "error")
        self.assertTrue(self.host.mappings[worker["map"]]["suspended"])
        with self.assertRaisesRegex(PRIVATE.FixtureError, "reload"):
            self.fixture.teardown()
        self.assertFalse(self.changes("kind", "delete"))
        self.assertFalse(self.changes("losetup", "--detach"))
        self.host.fail.clear()
        self.fixture.teardown()
        self.assertFalse(self.host.mappings)

    def test_rejects_changed_mapping_uuid_without_device_mutation(self):
        worker = self.ready()[0]
        self.host.mappings[worker["map"]]["uuid"] = "unrelated-owner"
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "UUID"):
            self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_rejects_changed_backing_device_without_device_mutation(self):
        worker = self.ready()[0]
        self.host.loops[worker["image"]]["maj:min"] = "7:999"
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "identity changed"):
            self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_rejects_corrupted_saved_table_before_device_mutation(self):
        worker = self.ready()[0]
        worker["table"] = "0 131072 linear 7:999 0"
        self.host.mappings[worker["map"]]["table"] = worker["table"]
        self.fixture.save()
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "table"):
            self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_wrong_endpoint_preserves_all_resources(self):
        self.ready()
        self.fixture.endpoint = "unix:///other-engine.sock"
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "endpoint mismatch"):
            self.fixture.teardown()
        self.assertFalse(self.host.calls)
        self.assertTrue(self.host.loops)

    def test_symlinked_ownership_marker_is_rejected(self):
        self.allocate()
        marker = self.fixture.directory / "owned"
        target = self.root / "other-owned"
        marker.rename(target)
        marker.symlink_to(target)
        with self.assertRaisesRegex(PRIVATE.FixtureError, "symlinks"):
            self.fixture.teardown()
        self.assertTrue(self.host.loops)

    def test_teardown_refuses_failed_engine_query(self):
        self.ready()
        self.host.fail.add("engine-query")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "engine-query"):
            self.fixture.teardown()
        self.assertFalse(self.changes("dmsetup", "remove"))
        self.assertFalse(self.changes("losetup", "--detach"))
        self.assertTrue((self.fixture.directory / "owned").exists())

    def test_failed_reference_cleanup_preserves_devices_and_retries(self):
        self.ready()
        self.host.fail.add("references")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "references"):
            self.fixture.teardown()
        self.assertFalse(self.changes("dmsetup", "remove"))
        self.assertFalse(self.changes("losetup", "--detach"))
        self.assertTrue((self.fixture.directory / "owned").exists())
        self.assertTrue(all(Path(worker["image"]).exists() for worker in self.fixture.state["workers"]))
        self.host.fail.remove("references")
        self.fixture.teardown()
        self.assertFalse(self.host.loops)
        self.assertFalse(self.host.mappings)

    def test_failed_node_removal_preserves_devices(self):
        self.ready()
        self.host.fail.add("kind-delete")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "kind-delete"):
            self.fixture.teardown()
        self.assertFalse(self.changes("dmsetup", "remove"))
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_teardown_removes_last_mapping_and_repeats_cleanly(self):
        workers = self.ready()
        self.fixture.teardown()
        self.assertFalse(self.host.mappings)
        self.assertFalse(self.host.loops)
        self.assertTrue(all(not Path(worker["image"]).exists() for worker in workers))
        self.assertEqual(self.state()["phase"], "Cleaned")
        self.assertFalse((self.fixture.directory / "owned").exists())
        self.assertIsNone(self.fixture.mapping(workers[-1]))
        self.fixture.teardown()
        with mock.patch("builtins.print"):
            self.fixture.verify_clean()

    def test_mapping_rejects_malformed_query_results(self):
        worker = self.allocate()[0]
        for output in ["Unexpected query output", "No devices found\ninvalid row"]:
            with self.subTest(output=output):
                with mock.patch.object(self.fixture, "privileged", return_value=output):
                    with self.assertRaisesRegex(PRIVATE.FixtureError, "Invalid device-mapper query result"):
                        self.fixture.mapping(worker)

    def test_teardown_refuses_failed_mapping_query(self):
        self.ready()
        self.host.fail.add("mapping-query")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "mapping-query"):
            self.fixture.teardown()
        self.assertTrue(self.host.mappings)
        self.assertTrue(self.host.loops)
        self.assertTrue((self.fixture.directory / "owned").exists())
        self.assertFalse(self.changes("dmsetup", "remove"))
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_detach_failure_preserves_only_unfinished_device_for_retry(self):
        workers = self.ready()
        self.host.fail.add("detach:3")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "detach:3"):
            self.fixture.teardown()
        self.assertTrue(Path(workers[-1]["image"]).exists())
        self.assertTrue(all(not Path(worker["image"]).exists() for worker in workers[:-1]))
        self.assertFalse(self.host.mappings)
        self.assertEqual(list(self.host.loops), [workers[-1]["image"]])
        self.assertFalse(self.state()["workers"][-1].get("removed", False))
        self.assertTrue((self.fixture.directory / "owned").exists())
        self.host.fail.clear()
        self.fixture.teardown()
        self.fixture.teardown()
        with mock.patch("builtins.print"):
            self.fixture.verify_clean()
        self.assertFalse(self.host.loops)
        self.assertFalse((self.fixture.directory / "owned").exists())

    def test_retry_finishes_interrupted_final_marker_removal(self):
        self.ready()
        owned = self.fixture.directory / "owned"
        unlink = Path.unlink

        def interrupted_unlink(path, *args, **kwargs):
            if path == owned:
                raise PermissionError("Injected ownership-marker removal failure")
            return unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", interrupted_unlink):
            with self.assertRaisesRegex(PermissionError, "ownership-marker"):
                self.fixture.teardown()
        self.assertEqual(self.state()["phase"], "Cleaned")
        self.assertTrue(owned.exists())
        self.assertTrue((self.fixture.lease / "fixture.json").exists())
        self.assertFalse(self.host.loops)
        self.assertFalse(self.host.mappings)
        self.fixture.teardown()
        self.assertFalse(owned.exists())
        self.assertFalse((self.fixture.lease / "fixture.json").exists())

    def test_deferred_detach_retains_image_until_association_disappears(self):
        worker = self.ready()[0]
        self.host.deferred.add(1)
        with self.assertRaisesRegex(PRIVATE.FixtureError, "detach is incomplete"):
            self.fixture.teardown()
        self.assertTrue(Path(worker["image"]).exists())
        self.assertIn(worker["image"], self.host.loops)
        self.host.deferred.clear()
        self.fixture.teardown()
        self.assertFalse(Path(worker["image"]).exists())

    def test_failed_loop_query_never_removes_image(self):
        worker = self.allocate()[0]
        self.host.fail.add("loop-query:1")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "loop-query:1"):
            self.fixture.teardown()
        self.assertTrue(Path(worker["image"]).exists())
        self.assertTrue((self.fixture.directory / "owned").exists())
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_busy_mapping_prevents_detach_and_preserves_image(self):
        worker = self.allocate()[0]
        self.host.mappings[worker["map"]]["open"] = 1
        with self.assertRaisesRegex(PRIVATE.FixtureError, "busy"):
            self.fixture.teardown()
        self.assertIn(worker["map"], self.host.mappings)
        self.assertTrue(Path(worker["image"]).exists())
        self.assertFalse(any(args == ["losetup", "--detach", worker["loop"]] for args, _ in self.host.calls))

    def test_lock_refuses_concurrent_operation_and_retains_owner(self):
        with mock.patch.object(self.fixture, "check_host"):
            with self.fixture.locked():
                owner = json.loads((self.fixture.directory / "operation.lock/owner.json").read_text())
                with self.assertRaisesRegex(PRIVATE.FixtureError, "lock exists"):
                    with self.fixture.locked():
                        self.fail("The second operation acquired the lock")
                self.assertEqual(json.loads((self.fixture.directory / "operation.lock/owner.json").read_text()), owner)
        self.assertFalse((self.fixture.directory / "operation.lock").exists())

    def test_prepare_records_identities_and_refuses_overwrite(self):
        worker, pod, pvc, pv = self.prepare()
        operation = self.operation()
        self.assertEqual(operation["phase"], "Prepared")
        self.assertEqual(operation["original"]["pod_uid"], pod["metadata"]["uid"])
        self.assertEqual(operation["original"]["pvc_uid"], pvc["metadata"]["uid"])
        self.assertEqual(operation["pv_uid"], pv["metadata"]["uid"])
        with self.assertRaisesRegex(PRIVATE.FixtureError, "unfinished"):
            self.fixture.reclaim(worker["node"], "test", "original", "prepare")
        self.assertEqual(self.operation(), operation)

    def test_reclaim_checks_conditional_patch_and_completes_after_binding(self):
        worker, _, _, _ = self.prepare()
        self.replacement()
        self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "Complete")
        self.assertEqual(self.host.patch_count, 1)
        self.assertEqual(self.host.patch_observations[0]["phase"], "PatchPending")
        self.assertEqual(self.host.patch_observations[0]["replacement"]["pod_uid"], "pod-replacement")
        patch_args = self.changes("kubectl", "--kubeconfig")
        patches = [args for args in patch_args if "patch" in args]
        patch = json.loads(patches[0][patches[0].index("-p") + 1])
        self.assertEqual([item["path"] for item in patch], [
            "/metadata/uid", "/metadata/resourceVersion", "/spec/claimRef", "/spec/claimRef"])
        self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.host.patch_count, 1)

    def test_reclaim_resolves_lost_patch_response(self):
        worker, _, _, _ = self.prepare()
        self.replacement()
        self.host.patch_mode = "lost-response"
        self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "Complete")
        self.assertEqual(self.host.patch_count, 1)

    def test_reclaim_rechecks_conflict_with_current_resource_version(self):
        worker, _, _, _ = self.prepare()
        self.replacement()
        self.host.patch_mode = "conflict"
        self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "Complete")
        self.assertEqual(self.host.patch_count, 2)
        self.assertEqual([op["resource_version"] for op in self.host.patch_observations], ["10", "11"])

    def test_timeout_before_patch_preserves_original_binding(self):
        worker, _, _, pv = self.prepare()
        original_ref = dict(pv["spec"]["claimRef"])
        self.consumer("replacement", "pod-replacement")
        with mock.patch.object(self.fixture, "pause", side_effect=self.expire_pause):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "deadline"):
                self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(pv["spec"]["claimRef"], original_ref)
        self.assertEqual(self.operation()["phase"], "Prepared")
        self.assertEqual(self.host.patch_count, 0)

    def test_timeout_after_patch_never_restores_original_binding(self):
        worker, _, _, pv = self.prepare()
        self.replacement()
        self.host.patch_mode = "release-only"
        with mock.patch.object(self.fixture, "pause", side_effect=self.expire_pause):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "deadline"):
                self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertNotIn("claimRef", pv["spec"])
        self.assertEqual(self.operation()["phase"], "Released")
        self.assertEqual(self.host.patch_count, 1)
        replacement = self.operation()["replacement"]
        pv["spec"]["claimRef"] = {"uid": replacement["pvc_uid"], "name": replacement["pvc"], "namespace": "test"}
        pv["status"]["phase"] = "Bound"
        pvc = self.host.pvcs[("test", "replacement-probe")]
        pvc["spec"]["volumeName"] = worker["pv"]
        pvc["status"]["phase"] = "Bound"
        self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "Complete")
        self.assertEqual(self.host.patch_count, 1)

    def test_reclaim_rejects_reused_original_consumer_identity(self):
        worker, _, _, _ = self.prepare()
        self.consumer("replacement", "pod-original")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "new Pod and PVC UIDs"):
            self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.host.patch_count, 0)

    def test_reclaim_rejects_unexpected_claim_without_mutation(self):
        worker, _, _, pv = self.prepare()
        self.replacement()
        unexpected = {"uid": "unrelated-claim", "name": "other", "namespace": "other"}
        pv["spec"]["claimRef"] = unexpected
        with self.assertRaisesRegex(PRIVATE.FixtureError, "unexpected claim"):
            self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(pv["spec"]["claimRef"], unexpected)
        self.assertEqual(self.host.patch_count, 0)

    def test_reclaim_rejects_changed_pv_uid_without_mutation(self):
        worker, _, _, pv = self.prepare()
        self.replacement()
        pv["metadata"]["uid"] = "replacement-pv"
        with self.assertRaisesRegex(PRIVATE.FixtureError, "PV identity"):
            self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.host.patch_count, 0)

    def test_reclaim_rejects_changed_pvc_owner_without_mutation(self):
        worker, _, _, _ = self.prepare()
        _, pvc = self.replacement()
        pvc["metadata"]["ownerReferences"][0]["uid"] = "unrelated-pod"
        with self.assertRaisesRegex(PRIVATE.FixtureError, "Pod owner"):
            self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.host.patch_count, 0)

    def test_reclaim_rejects_replacement_bound_to_another_pv(self):
        worker, _, _, pv = self.prepare()
        _, pvc = self.replacement()
        pvc["spec"]["volumeName"] = "unrelated-pv"
        pvc["status"]["phase"] = "Bound"
        original_ref = dict(pv["spec"]["claimRef"])
        with self.assertRaises(PRIVATE.FixtureError):
            self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(pv["spec"]["claimRef"], original_ref)
        self.assertEqual(self.host.patch_count, 0)

    def test_rejects_changed_node_uid_before_fault_mutation(self):
        worker = self.ready()[0]
        node = self.host.node(worker)
        node["metadata"]["uid"] = "new-node"
        self.host.calls.clear()
        with mock.patch.object(self.host, "node", return_value=node):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "Node identity"):
                self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_rejects_changed_container_before_fault_mutation(self):
        worker = self.ready()[0]
        container = self.host.container(worker)
        container["Id"] = "replacement-container"
        self.host.calls.clear()
        with mock.patch.object(self.host, "container", return_value=container):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "container identity"):
                self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_rejects_wrong_context_before_fault_mutation(self):
        worker = self.ready()[0]
        original_runner = self.fixture.runner

        def wrong_context(argv, **kwargs):
            if argv[-2:] == ["config", "current-context"]:
                return "unrelated-context"
            return original_runner(argv, **kwargs)

        self.fixture.runner = wrong_context
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "context"):
            self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_rejects_image_outside_fixture_without_touching_external_file(self):
        worker = self.allocate()[0]
        external = self.root / "external.img"
        external.write_text("other fixture")
        worker["image"] = str(external)
        self.fixture.save()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "backing image path"):
            self.fixture.teardown()
        self.assertEqual(external.read_text(), "other fixture")
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_replaced_image_inode_refuses_cleanup_without_device_mutation(self):
        worker = self.ready()[0]
        image = Path(worker["image"])
        original = image.with_name("original-image")
        image.rename(original)
        with image.open("wb") as replacement:
            replacement.truncate(64 * 1024 * 1024)
        self.assertNotEqual(image.stat().st_ino, original.stat().st_ino)
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "image.*identity|identity.*image"):
            self.fixture.teardown()
        self.assertTrue(image.exists())
        self.assertTrue(original.exists())
        self.assertFalse(self.changes("dmsetup", "suspend"))
        self.assertFalse(self.changes("dmsetup", "remove"))
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_existing_image_without_recorded_identity_requires_manual_recovery(self):
        worker = self.allocate()[0]
        worker.pop("image_identity")
        self.fixture.save()
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "image.*identity|identity.*image"):
            self.fixture.teardown()
        self.assertTrue(Path(worker["image"]).exists())
        self.assertTrue((self.fixture.directory / "owned").exists())
        self.assertFalse(self.changes("dmsetup", "suspend"))
        self.assertFalse(self.changes("dmsetup", "remove"))
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_reclaim_preserves_patchpending_when_patch_result_cannot_be_read(self):
        worker, _, _, pv = self.prepare()
        self.replacement()
        self.host.patch_mode = "lost-unreadable"
        with self.assertRaisesRegex(PRIVATE.FixtureError, "get:pv"):
            self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "PatchPending")
        self.assertNotIn("claimRef", pv["spec"])
        self.host.fail.clear()
        with mock.patch.object(self.fixture, "pause", side_effect=self.expire_pause):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "deadline"):
                self.fixture.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "Released")
        self.assertEqual(self.host.patch_count, 1)
        self.assertNotIn("claimRef", pv["spec"])

    def test_restart_uses_prepared_consumer_identities(self):
        worker, _, _, _ = self.prepare()
        self.replacement()
        resumed = PRIVATE.Fixture(self.fixture.directory, runner=self.host)
        resumed.endpoint = self.fixture.endpoint
        resumed.lease = self.fixture.lease
        self.host.fixture = resumed
        resumed.load()
        resumed.reclaim(worker["node"], "test", "replacement", "reclaim")
        self.assertEqual(self.operation()["phase"], "Complete")
        self.assertEqual(self.operation()["original"]["pod_uid"], "pod-original")
        self.assertEqual(self.host.patch_count, 1)

    def test_rejects_disabled_direct_io_before_fault_mutation(self):
        worker = self.ready()[0]
        self.host.loops[worker["image"]]["dio"] = 0
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "direct-I/O"):
            self.fixture.fault(worker["node"], "error")
        self.assertFalse(self.changes("dmsetup", "suspend"))

    def test_symlinked_state_file_is_rejected(self):
        self.allocate()
        state = self.fixture.directory / "fixture.json"
        target = self.root / "external-fixture.json"
        state.rename(target)
        state.symlink_to(target)
        with self.assertRaisesRegex(PRIVATE.FixtureError, "symlinks"):
            self.fixture.teardown()
        self.assertTrue(self.host.loops)
        self.assertFalse(self.changes("losetup", "--detach"))

    def test_same_cluster_endpoint_refuses_another_state_directory(self):
        self.allocate()
        lease_before = (self.fixture.lease / "fixture.json").read_text()
        second = PRIVATE.Fixture(self.root / "second-state", runner=self.host)
        second.endpoint = self.fixture.endpoint
        second.lease = self.fixture.lease
        with mock.patch.object(second, "check_host"):
            with self.assertRaisesRegex(PRIVATE.FixtureError, "another fixture directory"):
                with second.locked():
                    self.fail("A second fixture accepted the owned endpoint")
        self.assertEqual((self.fixture.lease / "fixture.json").read_text(), lease_before)
        self.assertTrue(self.host.loops)

    def test_changed_endpoint_owner_refuses_cleanup_before_device_mutation(self):
        self.ready()
        lease = self.fixture.lease / "fixture.json"
        lease.write_text(json.dumps({"directory": str(self.fixture.directory), "id": "a" * 32}))
        self.host.calls.clear()
        with self.assertRaisesRegex(PRIVATE.FixtureError, "ownership"):
            self.fixture.teardown()
        self.assertFalse(self.host.calls)
        self.assertTrue(self.host.loops)
        self.assertTrue(self.host.mappings)

    def test_host_check_rejects_remote_rootless_and_desktop_docker(self):
        cases = [
            ("ssh://remote-host", {"OperatingSystem": "Linux", "SecurityOptions": []}),
            ("unix:///var/run/docker.sock", {"OperatingSystem": "Linux", "SecurityOptions": ["rootless"]}),
            ("unix:///var/run/docker.sock", {"OperatingSystem": "Docker Desktop", "SecurityOptions": []}),
        ]
        for endpoint, info in cases:
            with self.subTest(endpoint=endpoint, info=info):
                def runner(argv, **kwargs):
                    if argv[-2:] == ["uname", "-s"]:
                        return "Linux"
                    if "context" in argv:
                        return endpoint
                    if "info" in argv:
                        return json.dumps(info)
                    if argv[-1] == "true":
                        return ""
                    raise AssertionError(argv)

                self.fixture.runner = runner
                with self.assertRaisesRegex(PRIVATE.FixtureError, "rootful Docker"):
                    self.fixture.check_host()

    def test_host_check_rejects_rootless_or_remote_podman(self):
        cases = [
            {"security": {"rootless": True}, "serviceIsRemote": False},
            {"security": {"rootless": False}, "serviceIsRemote": True},
        ]
        self.fixture.tool = "podman"
        for host in cases:
            with self.subTest(host=host):
                def runner(argv, **kwargs):
                    if argv[-2:] == ["uname", "-s"]:
                        return "Linux"
                    if "info" in argv:
                        return json.dumps({"host": host})
                    if argv[-1] == "true":
                        return ""
                    raise AssertionError(argv)

                self.fixture.runner = runner
                with self.assertRaisesRegex(PRIVATE.FixtureError, "rootful Podman"):
                    self.fixture.check_host()

    def test_host_check_rejects_macos_before_host_allocation(self):
        self.fixture.runner = mock.Mock(return_value="Darwin")
        with self.assertRaisesRegex(PRIVATE.FixtureError, "native Linux"):
            self.fixture.check_host()
        self.fixture.runner.assert_called_once_with(["uname", "-s"], timeout=10, input=None, check=True)


class PrivateModeSettings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kind-private-settings-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ)
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "KIND_HA", "KUBECONFIG"]:
            self.env.pop(key, None)
        self.env.update(
            KIND_BLOCK_STORAGE="true", KIND_BLOCK_MODE="per-node",
            KIND_BLOCK_STATE_DIR=str(self.root / "state"),
            MEDIK8S_CLUSTER_NAME="private-test", CONTAINER_TOOL="docker",
            KUBECTL="kubectl", SKIP_REGISTRY="true",
        )

    def reject(self, setting, *args, **extra):
        result = subprocess.run(
            ["bash", str(DEV / "setup.sh"), "--skip-olm", "--skip-inotify-check", *args],
            env=self.env | extra, capture_output=True, text=True, timeout=15,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(setting, result.stdout + result.stderr)
        self.assertFalse((self.root / "state" / "fixture.json").exists())

    def test_rejects_unknown_mode_before_allocation(self):
        self.reject("KIND_BLOCK_MODE", KIND_BLOCK_MODE="unknown")

    def test_rejects_worker_override_in_shared_mode(self):
        self.reject("KIND_BLOCK_WORKERS", KIND_BLOCK_MODE="shared", KIND_BLOCK_WORKERS="3")

    def test_rejects_invalid_private_worker_counts(self):
        for value in ["0", "2", "-1", "3.5", "three", ""]:
            with self.subTest(workers=value):
                self.reject("KIND_BLOCK_WORKERS", KIND_BLOCK_WORKERS=value)

    def test_rejects_private_mode_with_external_cluster(self):
        self.reject("--skip-kind", "--skip-kind")


if __name__ == "__main__":
    unittest.main()
