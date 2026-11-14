"""Check the private fixture with real Kubernetes binding and Linux block I/O."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import traceback


DEV = Path(__file__).resolve().parents[1]
LABEL = "medik8s.io/kind-block-fixture"
STORAGE_CLASS = "medik8s-kind-block-per-node"
DEVICE = "/dev/probe"


class PrivateBlockSmoke:
    def __init__(self):
        self.state_dir = Path(os.environ["KIND_BLOCK_STATE_DIR"])
        self.state = json.loads((self.state_dir / "fixture.json").read_text())
        self.artifacts = Path(os.environ.get("KIND_BLOCK_SMOKE_ARTIFACTS", "/tmp/kind-block-per-node-smoke"))
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.namespace = "private-block-smoke"
        self.kubectl = shlex.split(os.environ.get("KUBECTL", "kubectl"))
        self.faulted = set()
        self.outstanding = None
        self.pods = {}
        self.tokens = {}
        self.bindings = {}

    def run(self, command, timeout=30, check=True, data=None):
        result = subprocess.run(command, input=data, capture_output=True, text=True, timeout=timeout)
        with (self.artifacts / "commands.log").open("a") as log:
            log.write(f"$ {shlex.join(command)}\n{result.stdout}{result.stderr}\n")
        if check and result.returncode:
            raise RuntimeError(f"Command failed: {shlex.join(command)}\n{result.stdout}{result.stderr}")
        return result

    def kube(self, *args, **kwargs):
        return self.run([*self.kubectl, "--request-timeout=10s", *args], **kwargs)

    def get(self, resource, name, namespaced=True):
        args = ["get", resource, name, "-o", "json"]
        if namespaced:
            args += ["-n", self.namespace]
        return json.loads(self.kube(*args).stdout)

    def apply(self, resource):
        self.kube("apply", "-f", "-", data=json.dumps(resource))

    def helper(self, *args):
        self.run([sys.executable, str(DEV / "kind_block_per_node.py"), *args], timeout=135)

    def wait(self, description, condition, seconds=120):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(1)
        raise RuntimeError(f"Timed out: {description}")

    def pod(self, worker, name):
        return {
            "apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": name, "namespace": self.namespace, "labels": {LABEL: self.state["id"]}},
            "spec": {
                "restartPolicy": "Never", "terminationGracePeriodSeconds": 10,
                "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [{"matchExpressions": [{
                        "key": "kubernetes.io/hostname", "operator": "In", "values": [worker["hostname"]],
                    }]}],
                }}},
                "containers": [{
                    "name": "probe", "image": "ubuntu:24.04", "command": ["sleep", "infinity"],
                    "volumeDevices": [{"name": "probe", "devicePath": DEVICE}],
                    "volumeMounts": [{"name": "state", "mountPath": "/state"}],
                }],
                "volumes": [
                    {"name": "probe", "ephemeral": {"volumeClaimTemplate": {
                        "metadata": {"labels": {LABEL: self.state["id"]}},
                        "spec": {
                            "accessModes": ["ReadWriteOnce"], "volumeMode": "Block",
                            "storageClassName": STORAGE_CLASS,
                            "resources": {"requests": {"storage": "10Mi"}},
                        },
                    }}},
                    {"name": "state", "hostPath": {"path": "/var/lib/medik8s/state", "type": "DirectoryOrCreate"}},
                ],
            },
        }

    def ready(self, name):
        self.kube("wait", "--for=condition=Ready", f"pod/{name}", "-n", self.namespace,
                  "--timeout=120s", timeout=130)

    def check_binding(self, worker, name):
        pod = self.get("pod", name)
        claim = self.get("pvc", f"{name}-probe")
        pv = self.get("pv", worker["pv"], namespaced=False)
        node = self.get("node", worker["node"], namespaced=False)
        assert node["metadata"]["uid"] == worker["node_uid"], "Node UID changed"
        assert pod["spec"]["nodeName"] == worker["node"], "Pod uses the wrong worker"
        assert claim["status"]["phase"] == "Bound", "Probe PVC is not Bound"
        assert claim["spec"]["volumeName"] == worker["pv"], "Probe PVC uses the wrong PV"
        assert claim["spec"]["volumeMode"] == "Block"
        assert claim["spec"]["accessModes"] == ["ReadWriteOnce"]
        assert claim["spec"]["storageClassName"] == STORAGE_CLASS
        owners = [owner for owner in claim["metadata"]["ownerReferences"] if owner.get("controller")]
        assert len(owners) == 1 and owners[0]["uid"] == pod["metadata"]["uid"], "Wrong ephemeral PVC owner"
        assert owners[0]["kind"] == "Pod" and owners[0]["name"] == name
        assert pv["metadata"]["uid"] == worker["pv_uid"], "PV UID changed"
        assert pv["metadata"]["labels"][LABEL] == self.state["id"]
        assert pv["spec"]["claimRef"]["uid"] == claim["metadata"]["uid"], "Wrong PV claim UID"
        assert pv["spec"]["persistentVolumeReclaimPolicy"] == "Retain"
        assert pv["spec"]["volumeMode"] == "Block"
        assert pv["spec"]["accessModes"] == ["ReadWriteOnce"]
        assert pv["spec"]["local"]["path"] == "/dev/medik8s-kind-block"
        terms = pv["spec"]["nodeAffinity"]["required"]["nodeSelectorTerms"]
        assert terms == [{"matchExpressions": [{
            "key": "kubernetes.io/hostname", "operator": "In", "values": [worker["hostname"]],
        }]}], "PV must have exact worker affinity"
        result = {"pod": pod, "pvc": claim, "pv": pv, "node": node}
        (self.artifacts / f"{name}-binding.json").write_text(json.dumps(result, indent=2))
        return pod["metadata"]["uid"], claim["metadata"]["uid"]

    def exec(self, name, *command, **kwargs):
        return self.kube("exec", "-n", self.namespace, name, "--", *command, **kwargs)

    def write(self, worker, token):
        command = (
            f"printf '%-4096s' {shlex.quote(token)} | "
            f"dd of={DEVICE} bs=4096 count=1 seek=1 iflag=fullblock oflag=direct conv=notrunc status=none"
        )
        self.exec(self.pods[worker["node"]], "sh", "-ec", command)
        self.tokens[worker["node"]] = token

    def read(self, worker, check=True):
        return self.exec(self.pods[worker["node"]], "dd", f"if={DEVICE}", "bs=4096", "count=1",
                         "skip=1", "iflag=direct", "status=none", check=check)

    def check_reads(self, workers):
        for worker in workers:
            output = self.read(worker).stdout
            assert output == self.tokens[worker["node"]].ljust(4096), "Private device data changed"

    def healthy_io(self, workers, suffix):
        for index, worker in enumerate(workers):
            self.write(worker, f"{self.state['id']}-{suffix}-{index}")
        self.check_reads(workers)

    def fault(self, worker, action):
        if action != "restore":
            self.faulted.add(worker["node"])
        self.helper("fault", "--node", worker["node"], "--action", action)
        if action == "restore":
            self.faulted.discard(worker["node"])

    def check_faults(self, workers):
        victim, survivors = workers[0], workers[1:]
        try:
            self.fault(victim, "error")
            result = self.read(victim, check=False)
            assert result.returncode and "Input/output error" in result.stderr, "Device did not return an I/O error"
            self.healthy_io(survivors, "error-survivor")
        finally:
            self.fault(victim, "restore")
        self.check_reads(workers)
        try:
            self.fault(victim, "hang")
            command = [*self.kubectl, "exec", "-n", self.namespace, self.pods[victim["node"]], "--",
                       "sh", "-ec", f"echo IO_STARTED >&2; exec dd if={DEVICE} bs=4096 count=1 skip=1 iflag=direct status=none"]
            marker = self.artifacts / "hang-started.log"
            with marker.open("w") as log:
                self.outstanding = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log, text=True)
            self.wait("hung I/O command starts", lambda: "IO_STARTED" in marker.read_text(), seconds=15)
            time.sleep(3)
            assert self.outstanding.poll() is None, "Suspended device I/O completed before restore"
            self.healthy_io(survivors, "hang-survivor")
            assert self.outstanding.poll() is None, "Suspended device I/O did not remain unfinished"
        finally:
            self.fault(victim, "restore")
            self.finish_outstanding()
        self.check_reads(workers)

    def finish_outstanding(self):
        if self.outstanding is None:
            return
        output, _ = self.outstanding.communicate(timeout=20)
        assert self.outstanding.returncode == 0, "I/O did not recover after restore"
        assert output == self.tokens[self.state["workers"][0]["node"]].ljust(4096)
        self.outstanding = None

    def check_replacement(self, worker):
        old = self.pods[worker["node"]]
        sentinel = f"{self.state['id']}-host-state"
        sentinel_path = f"/state/{self.state['id']}-smoke-sentinel"
        self.exec(old, "sh", "-ec", f"printf '%s' {shlex.quote(sentinel)} > {shlex.quote(sentinel_path)}")
        self.helper("reclaim", "--node", worker["node"], "--namespace", self.namespace,
                    "--pod", old, "--action", "prepare")
        self.kube("delete", "pod", old, "-n", self.namespace, "--wait=true", "--timeout=60s", timeout=70)
        self.kube("wait", "--for=delete", f"pvc/{old}-probe", "-n", self.namespace,
                  "--timeout=60s", timeout=70)
        self.wait("old PV becomes Released", lambda: self.get("pv", worker["pv"], False)["status"]["phase"] == "Released")
        replacement = f"{old}-replacement"
        self.apply(self.pod(worker, replacement))
        self.wait("replacement ephemeral PVC exists", lambda: bool(self.kube(
            "get", "pvc", f"{replacement}-probe", "-n", self.namespace, "--ignore-not-found", "-o", "name").stdout))
        for _ in range(3):
            claim = self.get("pvc", f"{replacement}-probe")
            pod = self.get("pod", replacement)
            assert claim["status"]["phase"] == "Pending", "Replacement bound before explicit reclaim"
            assert not claim["spec"].get("volumeName"), "Replacement was prebound"
            assert pod["status"]["phase"] == "Pending", "Replacement ran before explicit reclaim"
            assert self.get("pv", worker["pv"], False)["status"]["phase"] == "Released"
            time.sleep(1)
        self.helper("reclaim", "--node", worker["node"], "--namespace", self.namespace,
                    "--pod", replacement, "--action", "reclaim")
        self.ready(replacement)
        current = self.check_binding(worker, replacement)
        assert all(before != after for before, after in zip(self.bindings[worker["node"]], current)), "Consumer UIDs did not change"
        assert self.exec(replacement, "cat", sentinel_path).stdout == sentinel, "Host state changed during reclaim"
        self.exec(replacement, "rm", sentinel_path)
        self.pods[worker["node"]] = replacement
        self.check_reads([worker])

    def exercise(self):
        workers = self.state["workers"]
        assert len(workers) >= 3, "Private smoke requires at least three workers"
        for field in ("node", "image", "loop", "map", "uuid", "pv", "pv_uid", "node_uid", "container_id"):
            assert len({worker[field] for worker in workers}) == len(workers), f"Duplicate {field}"
        for worker in workers:
            output = self.run(["sudo", "-n", "losetup", "--list", "--json", "--output", "NAME,BACK-FILE,DIO", worker["loop"]]).stdout
            devices = json.loads(output)["loopdevices"]
            assert len(devices) == 1 and devices[0]["dio"] in (True, 1, "1"), "Loop direct I/O is disabled"
            assert devices[0]["back-file"] == worker["image"], "Loop backing file changed"
        self.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {
            "name": self.namespace, "labels": {LABEL: self.state["id"], "pod-security.kubernetes.io/enforce": "privileged"},
        }})
        for index, worker in enumerate(workers):
            name = f"probe-{index}"
            self.pods[worker["node"]] = name
            self.apply(self.pod(worker, name))
        for worker in workers:
            name = self.pods[worker["node"]]
            self.ready(name)
            self.bindings[worker["node"]] = self.check_binding(worker, name)
        for index in (0, 1):
            assert len({value[index] for value in self.bindings.values()}) == len(workers), "Consumer UIDs are not distinct"
        self.healthy_io(workers, "initial")
        self.check_faults(workers)
        self.check_replacement(workers[0])
        self.kube("delete", "namespace", self.namespace, "--wait=true", "--timeout=90s", timeout=100)

    def diagnostics(self):
        for name, args in {
            "nodes.json": ["get", "nodes", "-o", "json"],
            "storage.json": ["get", "pv,pvc,pod", "-A", "-o", "json"],
            "events.txt": ["get", "events", "-A", "--sort-by=.metadata.creationTimestamp"],
        }.items():
            try:
                result = self.kube(*args, check=False)
                (self.artifacts / name).write_text(result.stdout + result.stderr)
            except Exception as error:
                (self.artifacts / name).write_text(str(error))


def main():
    smoke = PrivateBlockSmoke()
    try:
        smoke.exercise()
    finally:
        restore_errors = []
        for node in list(smoke.faulted):
            try:
                smoke.fault({"node": node}, "restore")
            except Exception as error:
                restore_errors.append(str(error))
        try:
            if not restore_errors:
                smoke.finish_outstanding()
            else:
                raise RuntimeError("Cannot restore fixture mappings: " + "\n".join(restore_errors))
        finally:
            smoke.diagnostics()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
