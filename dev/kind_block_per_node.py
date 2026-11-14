#!/usr/bin/env python3
"""Manage disposable private Block devices for a native Linux Kind cluster."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid


LABEL = "medik8s.io/kind-block-fixture"
STORAGE_CLASS = "medik8s-kind-block-per-node"
DEVICE = "/dev/medik8s-kind-block"
DEV = Path(__file__).resolve().parent


class FixtureError(RuntimeError):
    pass


def command(argv, timeout=10, input=None, check=True):
    process = subprocess.Popen(
        argv, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        raise FixtureError(f"Command deadline expired: {shlex.join(argv)}")
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            try:
                process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        raise
    if check and process.returncode:
        raise FixtureError(f"Command failed: {shlex.join(argv)}\n{stderr.strip()}")
    return stdout.strip()


def safe_path(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise FixtureError(f"An absolute path without symlinks is required: {path}")
    return path


def read_json(path):
    safe_path(path)
    return json.loads(path.read_text())


def write_json(path, value):
    safe_path(path)
    temporary = path.with_name(path.name + ".new")
    safe_path(temporary)
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class Fixture:
    def __init__(self, directory=None, runner=None):
        self.cluster = os.environ.get("MEDIK8S_CLUSTER_NAME", "medik8s-dev")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", self.cluster):
            raise FixtureError("Invalid Kind cluster name.")
        default = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        requested = Path(directory or os.environ.get(
            "KIND_BLOCK_STATE_DIR", str(default / "medik8s/kind-block" / self.cluster)))
        if not requested.is_absolute() or requested.is_symlink():
            raise FixtureError("KIND_BLOCK_STATE_DIR must be an absolute directory without a symlink.")
        self.directory = safe_path(requested.resolve())
        self.runner = runner or command
        self.tool = os.environ.get("CONTAINER_TOOL", "docker")
        self.kubectl = shlex.split(os.environ.get("KUBECTL", "kubectl"))
        self.state = None
        self.deadline = None
        self.endpoint = None
        self.lease = None

    def run(self, *args, timeout=10, input=None, check=True):
        if self.deadline is not None:
            timeout = min(timeout, self.deadline - time.monotonic())
            if timeout <= 0:
                raise FixtureError("The 120-second action deadline expired.")
        return self.runner(list(args), timeout=timeout, input=input, check=check)

    def privileged(self, *args, **kwargs):
        prefix = [] if os.geteuid() == 0 else ["sudo", "-n"]
        return self.run(*prefix, *args, **kwargs)

    def kube(self, *args, **kwargs):
        return self.run(*self.kubectl, "--kubeconfig", str(self.directory / "kubeconfig"),
                        "--request-timeout=10s", *args, **kwargs)

    def get(self, kind, name, namespace=None):
        args = ["get", kind, name, "--ignore-not-found", "-o", "json"]
        if namespace:
            args.extend(["-n", namespace])
        value = self.kube(*args)
        return json.loads(value) if value else None

    def require(self, condition, message):
        if not condition:
            raise FixtureError(message)

    def check_host(self):
        self.require(self.run("uname", "-s") == "Linux", "Private Block storage requires native Linux.")
        self.require(self.tool in ("docker", "podman"), "Use CONTAINER_TOOL=docker or podman.")
        self.privileged("true")
        if self.tool == "docker":
            context = os.environ.get("DOCKER_CONTEXT")
            if context:
                self.endpoint = self.run("docker", "context", "inspect", context,
                                         "--format", "{{.Endpoints.docker.Host}}")
            else:
                self.endpoint = os.environ.get("DOCKER_HOST") or self.run(
                    "docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}")
            info = json.loads(self.run("docker", "info", "--format", "{{json .}}"))
            self.require(self.endpoint.startswith("unix://") and
                         "Docker Desktop" not in info.get("OperatingSystem", "") and
                         "rootless" not in json.dumps(info.get("SecurityOptions", [])).lower(),
                         "Private Block storage requires local rootful Docker.")
            self.endpoint = "unix://" + str(Path(self.endpoint[7:]).resolve())
        else:
            info = json.loads(self.run("podman", "info", "--format", "json"))
            host = info.get("host", {})
            self.require(host.get("security", {}).get("rootless") is False and
                         host.get("serviceIsRemote") is False and
                         not os.environ.get("CONTAINER_HOST") and
                         not os.environ.get("CONTAINER_CONNECTION"),
                         "Private Block storage requires native, rootful Podman without a remote connection.")
            self.endpoint = "podman-local-rootful"
        key = hashlib.sha256(f"{self.tool}:{self.endpoint}:{self.cluster}".encode()).hexdigest()
        self.lease = safe_path(Path("/tmp").resolve() / f"medik8s-kind-block-{key}")

    @contextmanager
    def locked(self):
        self.check_host()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lease.mkdir(mode=0o700, exist_ok=True)
        owner = {"pid": os.getpid(), "token": uuid.uuid4().hex, "directory": str(self.directory)}
        acquired = []
        try:
            for path in (self.lease / "lock", self.directory / "operation.lock"):
                safe_path(path)
                try:
                    path.mkdir(mode=0o700)
                except FileExistsError:
                    raise FixtureError(f"Fixture lock exists. Check its owner before manual recovery: {path}")
                acquired.append(path)
                write_json(path / "owner.json", owner)
            marker = self.lease / "fixture.json"
            if marker.exists():
                self.require(read_json(marker)["directory"] == str(self.directory),
                             "This cluster and endpoint belong to another fixture directory.")
            previous = os.environ.get("_MEDIK8S_KIND_BLOCK_SESSION")
            os.environ["_MEDIK8S_KIND_BLOCK_SESSION"] = json.dumps(owner)
            try:
                yield
            finally:
                if previous is None:
                    os.environ.pop("_MEDIK8S_KIND_BLOCK_SESSION", None)
                else:
                    os.environ["_MEDIK8S_KIND_BLOCK_SESSION"] = previous
        finally:
            for path in reversed(acquired):
                (path / "owner.json").unlink(missing_ok=True)
                path.rmdir()

    def session(self):
        self.check_host()
        owner = json.loads(os.environ.get("_MEDIK8S_KIND_BLOCK_SESSION", "{}"))
        self.require(owner.get("directory") == str(self.directory) and
                     read_json(self.directory / "operation.lock/owner.json") == owner and
                     read_json(self.lease / "lock/owner.json") == owner,
                     "An active fixture wrapper must hold both locks.")
        os.kill(owner["pid"], 0)

    def load(self):
        self.state = read_json(self.directory / "fixture.json")
        self.require(self.state["cluster"] == self.cluster and self.state["tool"] == self.tool and
                     self.state["endpoint"] == self.endpoint, "Fixture cluster or endpoint mismatch.")
        self.require(re.fullmatch(r"[0-9a-f]{32}", self.state["id"]), "Invalid fixture identifier.")
        safe_path(self.directory / "owned")
        if self.state["phase"] != "Cleaned":
            self.require((self.directory / "owned").read_text().strip() == self.state["id"],
                         "Fixture ownership mismatch.")
            if self.lease is not None:
                self.require(read_json(self.lease / "fixture.json") ==
                             {"directory": str(self.directory), "id": self.state["id"]},
                             "Endpoint ownership mismatch.")
        return self.state

    def save(self):
        write_json(self.directory / "fixture.json", self.state)

    def loops(self, worker):
        expected = self.directory / "devices" / f"{worker['index']}.img"
        self.require(safe_path(worker["image"]) == expected, "Unexpected backing image path.")
        if expected.exists():
            info = expected.stat()
            self.require(worker.get("image_identity") == {"device": info.st_dev, "inode": info.st_ino},
                         "The backing image identity is absent or changed. Preserve this file for inspection.")
        result = json.loads(self.privileged("losetup", "--associated", str(expected), "--json",
                                           "--output", "NAME,BACK-FILE,DIO,MAJ:MIN"))
        loops = result.get("loopdevices", []) or []
        self.require(len(loops) <= 1, "Multiple loop devices use one backing file.")
        for item in loops:
            self.require(item["back-file"] == str(expected) and
                         re.fullmatch(r"/dev/loop[0-9]+", item["name"]), "Backing file association mismatch.")
            if worker.get("loop"):
                self.require(item["name"] == worker["loop"] and
                             item["maj:min"] == worker["loop_identity"], "Loop device identity changed.")
        return loops

    def mapping(self, worker):
        expected = f"medik8s-{self.state['id']}-{worker['index']}"
        self.require(worker["map"] == expected and worker["uuid"] == expected,
                     "Unexpected device-mapper identity.")
        output = self.privileged("dmsetup", "info", "--columns", "--noheadings",
                                 "--separator", "|", "-o", "name,uuid,open,suspended")
        if output.strip() == "No devices found":
            return None
        for line in output.splitlines():
            fields = [value.strip() for value in line.split("|")]
            self.require(len(fields) == 4, "Invalid device-mapper query result.")
            if fields[0] == worker["map"]:
                self.require(fields[1] == worker["uuid"], "Device-mapper UUID mismatch.")
                return {"open": int(fields[2]), "suspended": fields[3].lower() == "suspended"}
        return None

    def validate_worker(self, worker, cluster=True):
        loops = self.loops(worker)
        self.require(len(loops) == 1 and loops[0]["dio"] in (1, True, "1"),
                     "The recorded direct-I/O loop device is absent or changed.")
        self.require(worker["table"] == f"0 131072 linear {loops[0]['maj:min']} 0",
                     "The saved mapping table does not use this worker's backing loop.")
        mapping = self.mapping(worker)
        self.require(mapping is not None, "The recorded device-mapper mapping is absent.")
        table = self.privileged("dmsetup", "table", worker["map"])
        error_table = " ".join(worker["table"].split()[:2]) + " error"
        self.require(" ".join(table.split()) in (worker["table"], error_table),
                     "The device-mapper table changed outside this fixture.")
        if cluster:
            self.require(self.kube("config", "current-context") == f"kind-{self.cluster}",
                         "Unexpected Kubernetes context.")
            node = self.get("node", worker["node"])
            self.require(node and node["metadata"]["uid"] == worker["node_uid"] and
                         node["metadata"]["labels"].get("kubernetes.io/hostname") == worker["hostname"] and
                         node["metadata"]["labels"].get(LABEL) == self.state["id"],
                         "Node identity or fixture label mismatch.")
            containers = json.loads(self.run(self.tool, "inspect", worker["node"]))
            container = containers[0]
            self.require(container["Id"] == worker["container_id"] and
                         container["Config"]["Labels"].get("io.x-k8s.kind.cluster") == self.cluster,
                         "Kind container identity mismatch.")
            mounts = [m for m in container["Mounts"] if m["Destination"] == DEVICE]
            self.require(len(mounts) == 1 and mounts[0]["Source"] == f"/dev/mapper/{worker['map']}",
                         "Kind device mount mismatch.")
            self.run(self.tool, "exec", worker["container_id"], "test", "-b", DEVICE)
        return mapping

    def allocate(self):
        self.require(not (self.directory / "owned").exists() and
                     not (self.directory / "owned").is_symlink(), "An unfinished private fixture exists.")
        raw_count = os.environ.get("KIND_BLOCK_WORKERS", "3")
        self.require(re.fullmatch(r"[0-9]+", raw_count) and int(raw_count) >= 3,
                     "KIND_BLOCK_WORKERS must be an integer of at least 3.")
        targets = self.privileged("dmsetup", "targets")
        self.require(all(re.search(rf"(?m)^\s*{target}\s", targets) for target in ("linear", "error")),
                     "Device-mapper linear and error targets are required.")
        self.require(not self.run("kind", "get", "clusters").splitlines().count(self.cluster),
                     "This Kind cluster already exists.")
        identifier = uuid.uuid4().hex
        self.state = {"id": identifier, "cluster": self.cluster, "endpoint": self.endpoint,
                      "tool": self.tool, "phase": "Allocating", "workers": []}
        safe_path(self.directory / "owned").write_text(identifier + "\n")
        self.save()
        write_json(self.lease / "fixture.json", {"directory": str(self.directory), "id": identifier})
        safe_path(self.directory / "devices").mkdir(exist_ok=True)
        for index in range(1, int(raw_count) + 1):
            node = f"{self.cluster}-worker" + (str(index) if index > 1 else "")
            name = f"medik8s-{identifier}-{index}"
            worker = {"index": index, "node": node, "image": str(self.directory / "devices" / f"{index}.img"),
                      "map": name, "uuid": name, "pv": name, "fault": "restore"}
            self.state["workers"].append(worker)
            self.save()
            with Path(worker["image"]).open("xb") as image:
                info = os.fstat(image.fileno())
                worker["image_identity"] = {"device": info.st_dev, "inode": info.st_ino}
                self.save()
            self.run("truncate", "-s", "64M", worker["image"])
            self.require(not self.loops(worker), "The new backing image already has a loop association.")
            self.privileged("losetup", "--find", "--direct-io=on", "--show", worker["image"])
            loops = self.loops(worker)
            self.require(len(loops) == 1 and loops[0]["dio"] in (1, True, "1"),
                         "Loop allocation did not enable direct I/O.")
            worker.update(loop=loops[0]["name"], loop_identity=loops[0]["maj:min"])
            self.save()
            sectors = self.privileged("blockdev", "--getsz", worker["loop"])
            self.require(sectors == "131072", "Unexpected backing device size.")
            worker["table"] = f"0 {sectors} linear {worker['loop_identity']} 0"
            self.save()
            self.privileged("dmsetup", "create", name, "--uuid", name, "--table", worker["table"])
            self.validate_worker(worker, cluster=False)
        self.generate_config()
        self.state["phase"] = "Allocated"
        self.save()

    def generate_config(self):
        nodes = [{"role": "control-plane"} for _ in range(3 if os.environ.get("KIND_HA") == "true" else 1)]
        for worker in self.state["workers"]:
            nodes.append({"role": "worker", "labels": {LABEL: self.state["id"], "medik8s.io/kind-block": "true"},
                          "extraMounts": [{"hostPath": f"/dev/mapper/{worker['map']}", "containerPath": DEVICE}]})
        config = {"kind": "Cluster", "apiVersion": "kind.x-k8s.io/v1alpha4", "nodes": nodes,
                  "networking": {"podSubnet": os.environ.get("KIND_POD_SUBNET", "10.244.0.0/16"),
                                 "serviceSubnet": os.environ.get("KIND_SERVICE_SUBNET", "10.96.0.0/16")},
                  "containerdConfigPatches": ['[plugins."io.containerd.grpc.v1.cri".registry]\n'
                                              '  config_path = "/etc/containerd/certs.d"']}
        write_json(self.directory / "kind.yaml", config)

    def install(self):
        self.load()
        self.require(self.kube("config", "current-context") == f"kind-{self.cluster}", "Unexpected Kubernetes context.")
        nodes = json.loads(self.kube("get", "nodes", "-l", f"{LABEL}={self.state['id']}", "-o", "json"))["items"]
        self.require({n["metadata"]["name"] for n in nodes} == {w["node"] for w in self.state["workers"]},
                     "The selected worker list does not match the fixture.")
        for worker in self.state["workers"]:
            node = next(n for n in nodes if n["metadata"]["name"] == worker["node"])
            worker.update(node_uid=node["metadata"]["uid"], hostname=node["metadata"]["labels"]["kubernetes.io/hostname"],
                          container_id=json.loads(self.run(self.tool, "inspect", worker["node"]))[0]["Id"])
            self.save()
            self.validate_worker(worker)
        manifests = [{"apiVersion": "storage.k8s.io/v1", "kind": "StorageClass",
                      "metadata": {"name": STORAGE_CLASS, "labels": {LABEL: self.state["id"]}},
                      "provisioner": "kubernetes.io/no-provisioner", "volumeBindingMode": "WaitForFirstConsumer"}]
        for worker in self.state["workers"]:
            manifests.append({"apiVersion": "v1", "kind": "PersistentVolume",
                              "metadata": {"name": worker["pv"], "labels": {LABEL: self.state["id"]}},
                              "spec": {"capacity": {"storage": "64Mi"}, "accessModes": ["ReadWriteOnce"],
                                       "volumeMode": "Block", "persistentVolumeReclaimPolicy": "Retain",
                                       "storageClassName": STORAGE_CLASS, "local": {"path": DEVICE},
                                       "nodeAffinity": {"required": {"nodeSelectorTerms": [{"matchExpressions": [
                                           {"key": "kubernetes.io/hostname", "operator": "In", "values": [worker["hostname"]]}]}]}}}})
        manifest = {"apiVersion": "v1", "kind": "List", "items": manifests}
        write_json(self.directory / "storage.json", manifest)
        self.kube("create", "-f", str(self.directory / "storage.json"))
        for worker in self.state["workers"]:
            pv = self.get("pv", worker["pv"])
            self.require(pv is not None, "The fixture PV is absent after creation.")
            worker["pv_uid"] = pv["metadata"]["uid"]
            self.save()
            self.validate_pv(worker, pv)
        self.state["phase"] = "Ready"
        self.save()
        print(f"Private raw Block storage ready: {len(self.state['workers'])} workers, StorageClass {STORAGE_CLASS}.")

    def worker(self, node):
        workers = [w for w in self.state["workers"] if w["node"] == node]
        self.require(len(workers) == 1, "The node does not belong to this fixture.")
        return workers[0]

    def validate_pv(self, worker, pv):
        spec = pv["spec"]
        self.require(pv["metadata"]["uid"] == worker["pv_uid"] and
                     pv["metadata"].get("labels", {}).get(LABEL) == self.state["id"] and
                     spec.get("volumeMode") == "Block" and spec.get("accessModes") == ["ReadWriteOnce"] and
                     spec.get("storageClassName") == STORAGE_CLASS and
                     spec.get("persistentVolumeReclaimPolicy") == "Retain" and
                     spec.get("capacity", {}).get("storage") == "64Mi" and
                     spec.get("local") == {"path": DEVICE} and
                     spec.get("nodeAffinity", {}).get("required", {}).get("nodeSelectorTerms") == [
                         {"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In",
                                                "values": [worker["hostname"]]}]}],
                     "PV identity, device, mode, or node affinity mismatch.")

    def fault(self, node, action):
        self.deadline = self.deadline or time.monotonic() + 10
        self.load()
        worker = self.worker(node)
        self.require(action in ("error", "hang", "restore"), "Unknown fault action.")
        self.validate_worker(worker)
        self.change_mapping(worker, action)

    def change_mapping(self, worker, action):
        worker["fault"] = action
        self.save()
        mapping = self.validate_worker(worker, cluster=False)
        if not mapping["suspended"]:
            self.privileged("dmsetup", "suspend", "--noflush", "--nolockfs", worker["map"])
        if action != "hang":
            table = worker["table"] if action == "restore" else " ".join(worker["table"].split()[:2]) + " error"
            self.privileged("dmsetup", "reload", worker["map"], "--table", table)
            self.privileged("dmsetup", "resume", "--noflush", "--nolockfs", worker["map"])
        mapping = self.mapping(worker)
        actual = self.privileged("dmsetup", "table", worker["map"])
        self.require(mapping and mapping["suspended"] == (action == "hang") and
                     (action == "hang" or " ".join(actual.split()) == table), "The mapping did not reach its requested state.")
        worker["fault_observed"] = action
        self.save()

    def consumer(self, worker, namespace, name):
        pod = self.get("pod", name, namespace)
        if pod is None:
            return None
        meta, spec = pod["metadata"], pod["spec"]
        self.require(meta.get("labels", {}).get(LABEL) == self.state["id"] and not meta.get("deletionTimestamp"),
                     "Consumer Pod fixture label or deletion state mismatch.")
        required = spec.get("affinity", {}).get("nodeAffinity", {}).get(
            "requiredDuringSchedulingIgnoredDuringExecution", {}).get("nodeSelectorTerms")
        self.require(required == [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In",
                                                        "values": [worker["hostname"]]}]}] and
                     spec.get("nodeName", worker["node"]) == worker["node"], "Consumer Pod node affinity mismatch.")
        volumes = [v for v in spec.get("volumes", []) if "ephemeral" in v and
                   v["ephemeral"]["volumeClaimTemplate"]["spec"].get("storageClassName") == STORAGE_CLASS]
        self.require(len(volumes) == 1, "The Pod must have one private generic ephemeral probe.")
        volume = volumes[0]
        self.require(any(d.get("name") == volume["name"] for c in spec["containers"] for d in c.get("volumeDevices", [])),
                     "The consumer does not use a raw volumeDevice.")
        pvc_name = f"{name}-{volume['name']}"
        pvc = self.get("pvc", pvc_name, namespace)
        if pvc is None:
            return None
        claim = pvc["spec"]
        self.require(not pvc["metadata"].get("deletionTimestamp") and
                     pvc["metadata"].get("labels", {}).get(LABEL) == self.state["id"] and
                     claim.get("volumeMode") == "Block" and claim.get("accessModes") == ["ReadWriteOnce"] and
                     claim.get("storageClassName") == STORAGE_CLASS and
                     claim.get("resources", {}).get("requests", {}).get("storage") == "10Mi" and
                     {"apiVersion": "v1", "kind": "Pod", "name": name, "uid": meta["uid"],
                      "controller": True, "blockOwnerDeletion": True} in pvc["metadata"].get("ownerReferences", []),
                     "PVC mode, fixture label, or Pod owner mismatch.")
        template = volume["ephemeral"]["volumeClaimTemplate"]["spec"]
        self.require(not template.get("volumeName") and template.get("volumeMode") == "Block" and
                     template.get("accessModes") == ["ReadWriteOnce"] and
                     template.get("resources", {}).get("requests", {}).get("storage") == "10Mi",
                     "The ephemeral claim template must request an unbound RWO Block volume.")
        return {"pod": name, "pod_uid": meta["uid"], "pvc": pvc_name, "pvc_uid": pvc["metadata"]["uid"],
                "namespace": namespace, "volume": claim.get("volumeName"), "pvc_phase": pvc.get("status", {}).get("phase")}

    def old_consumers_gone(self, worker, original):
        for kind, name, identity in (("pod", original["pod"], original["pod_uid"]),
                                     ("pvc", original["pvc"], original["pvc_uid"])):
            obj = self.get(kind, name, original["namespace"])
            if obj and obj["metadata"]["uid"] == identity:
                return False
        containers = json.loads(self.run(self.tool, "exec", worker["container_id"], "crictl", "ps", "-o", "json"))
        self.require(not any(c.get("labels", {}).get("io.kubernetes.pod.uid") == original["pod_uid"]
                             for c in containers.get("containers", [])), "An original consumer container is still running.")
        self.require(re.fullmatch(r"[A-Za-z0-9-]+", original["pod_uid"]), "Invalid original Pod UID.")
        script = ('test ! -d /var/lib/kubelet/pods/' + original["pod_uid"] + '/volumeDevices && '
                  '! grep -F /pods/' + original["pod_uid"] + '/ /proc/self/mountinfo')
        self.run(self.tool, "exec", worker["container_id"], "sh", "-c", script)
        self.require(self.mapping(worker)["open"] == 0, "The private device still has open consumers.")
        return True

    def reclaim(self, node, namespace, pod, action):
        self.deadline = self.deadline or time.monotonic() + 120
        self.load()
        worker = self.worker(node)
        self.validate_worker(worker)
        path = self.directory / f"reclaim-{worker['index']}.json"
        self.require(action in ("prepare", "reclaim"), "Unknown reclaim action.")
        if action == "prepare":
            if path.exists():
                self.require(read_json(path)["phase"] == "Complete", "An unfinished reclaim operation exists.")
            original = self.consumer(worker, namespace, pod)
            self.require(original and original["volume"] == worker["pv"] and original["pvc_phase"] == "Bound",
                         "The original consumer must own this worker's bound PV.")
            pv = self.get("pv", worker["pv"])
            self.validate_pv(worker, pv)
            self.require(self.claim_matches(pv["spec"].get("claimRef"), original), "The PV does not name the original claim.")
            write_json(path, {"phase": "Prepared", "node_uid": worker["node_uid"], "pv_uid": worker["pv_uid"],
                              "fixture": self.state["id"], "original": original})
            return
        operation = read_json(path)
        self.require(operation["node_uid"] == worker["node_uid"] and operation["pv_uid"] == worker["pv_uid"] and
                     operation["fixture"] == self.state["id"], "Reclaim record identity mismatch.")
        original = operation["original"]
        while True:
            replacement = self.consumer(worker, namespace, pod)
            if replacement:
                break
            self.pause()
        self.require(replacement["pod_uid"] != original["pod_uid"] and replacement["pvc_uid"] != original["pvc_uid"],
                     "The replacement must have new Pod and PVC UIDs.")
        self.require(not replacement["volume"] or replacement["volume"] == worker["pv"],
                     "The replacement claim is bound to another PV.")
        if operation.get("replacement"):
            self.require(operation["replacement"] == replacement or
                         all(operation["replacement"][k] == replacement[k] for k in
                             ("namespace", "pod", "pod_uid", "pvc", "pvc_uid")), "Replacement identity changed during reclaim.")
        else:
            operation["replacement"] = replacement
            write_json(path, operation)
        while True:
            self.validate_worker(worker)
            current = self.consumer(worker, namespace, pod)
            self.require(current and all(current[k] == replacement[k] for k in
                                         ("namespace", "pod", "pod_uid", "pvc", "pvc_uid")), "Replacement identity changed.")
            pv = self.get("pv", worker["pv"])
            self.validate_pv(worker, pv)
            ref = pv["spec"].get("claimRef")
            if self.claim_matches(ref, replacement):
                if current["volume"] == worker["pv"] and current["pvc_phase"] == "Bound" and pv["status"]["phase"] == "Bound":
                    operation["phase"] = "Complete"
                    write_json(path, operation)
                    return
            elif ref is None:
                self.require(operation["phase"] in ("PatchPending", "Released"), "The original binding disappeared before reclaim.")
                operation["phase"] = "Released"
                write_json(path, operation)
            elif self.claim_matches(ref, original):
                self.require(operation["phase"] in ("Prepared", "PatchPending"), "The original binding returned after release.")
                if not self.old_consumers_gone(worker, original) or pv["status"]["phase"] != "Released":
                    self.pause()
                    continue
                operation.update(phase="PatchPending", resource_version=pv["metadata"]["resourceVersion"])
                write_json(path, operation)
                patch = [{"op": "test", "path": "/metadata/uid", "value": worker["pv_uid"]},
                         {"op": "test", "path": "/metadata/resourceVersion", "value": operation["resource_version"]},
                         {"op": "test", "path": "/spec/claimRef", "value": ref},
                         {"op": "remove", "path": "/spec/claimRef"}]
                try:
                    self.kube("patch", "pv", worker["pv"], "--type=json", "-p", json.dumps(patch))
                except FixtureError:
                    # A failed response can follow a successful patch. Resolve it through the next live read.
                    pass
                continue
            else:
                raise FixtureError("An unexpected claim owns this PV. No binding was changed.")
            self.pause()

    @staticmethod
    def claim_matches(ref, consumer):
        return ref and ref.get("uid") == consumer["pvc_uid"] and ref.get("name") == consumer["pvc"] and ref.get("namespace") == consumer["namespace"]

    def pause(self):
        remaining = self.deadline - time.monotonic()
        self.require(remaining > 0, "The 120-second action deadline expired. The operation record remains available.")
        time.sleep(min(1, remaining))

    def teardown(self):
        if not (self.directory / "fixture.json").exists():
            self.require(not (self.directory / "owned").exists(), "An unknown fixture owns this directory.")
            return
        self.load()
        if self.state["phase"] == "Cleaned":
            self.finish_cleanup()
            return
        for worker in self.state["workers"]:
            if self.mapping(worker):
                self.change_mapping(worker, "restore")
        containers = self.run(self.tool, "ps", "-aq", "--filter", f"label=io.x-k8s.kind.cluster={self.cluster}")
        if containers:
            for identity in containers.splitlines():
                container = json.loads(self.run(self.tool, "inspect", identity))[0]
                self.require(container["Config"]["Labels"].get("io.x-k8s.kind.cluster") == self.cluster,
                             "Unexpected cluster container during teardown.")
                name = container["Name"].lstrip("/")
                recorded = next((w for w in self.state["workers"] if w["node"] == name), None)
                if recorded:
                    if recorded.get("container_id"):
                        self.require(recorded["container_id"] == container["Id"], "The node container changed.")
                    mounts = [m for m in container["Mounts"] if m["Destination"] == DEVICE]
                    self.require(len(mounts) == 1 and mounts[0]["Source"] == f"/dev/mapper/{recorded['map']}",
                                 "The worker mount does not belong to this fixture.")
                else:
                    self.require(name == self.cluster + "-control-plane" or
                                 name in (self.cluster + "-control-plane2", self.cluster + "-control-plane3"),
                                 "An unknown container uses this cluster name.")
            try:
                self.require(self.kube("config", "current-context") == f"kind-{self.cluster}", "Unexpected Kubernetes context.")
                self.kube("delete", "pods", "-A", "-l", f"{LABEL}={self.state['id']}", "--wait=false")
            except FixtureError as error:
                print(f"Consumer deletion failed. Kind node removal will stop consumers: {error}", file=sys.stderr)
            self.run("kind", "delete", "cluster", "--name", self.cluster, timeout=120)
        self.require(not self.run(self.tool, "ps", "-aq", "--filter", f"label=io.x-k8s.kind.cluster={self.cluster}"),
                     "Kind nodes remain. Devices and backing images remain available for retry.")
        failures = []
        for worker in self.state["workers"]:
            try:
                loops = self.loops(worker)
                mapping = self.mapping(worker)
                if mapping:
                    self.require(loops, "A mapping exists without its backing loop device.")
                    self.validate_worker(worker, cluster=False)
                    self.privileged("python3", str(Path(__file__).with_name("kind_block_references.py")),
                                    f"/dev/mapper/{worker['map']}")
                    mapping = self.mapping(worker)
                    self.require(mapping["open"] == 0, "The mapping is busy.")
                    self.privileged("dmsetup", "remove", worker["map"])
                    self.require(self.mapping(worker) is None, "Device-mapper removal is incomplete.")
                if loops:
                    self.privileged("losetup", "--detach", loops[0]["name"])
                    self.require(not self.loops(worker), "Loop detach is incomplete. The backing image remains available.")
                safe_path(worker["image"]).unlink(missing_ok=True)
                worker["removed"] = True
                self.save()
            except (FixtureError, OSError, ValueError) as error:
                failures.append(f"{worker['node']}: {error}")
        self.require(not failures, "Cleanup requires a retry:\n" + "\n".join(failures))
        self.state["phase"] = "Cleaned"
        self.save()
        self.finish_cleanup()

    def finish_cleanup(self):
        owned = safe_path(self.directory / "owned")
        lease = self.lease / "fixture.json"
        if owned.exists():
            self.require(owned.read_text().strip() == self.state["id"], "Fixture ownership changed.")
        if lease.exists():
            self.require(read_json(lease) == {"directory": str(self.directory), "id": self.state["id"]}, "Endpoint ownership changed.")
        self.verify_resources_absent()
        owned.unlink(missing_ok=True)
        lease.unlink(missing_ok=True)

    def verify_clean(self):
        self.load()
        self.require(self.state["phase"] == "Cleaned" and not (self.directory / "owned").exists(), "Fixture cleanup is incomplete.")
        self.verify_resources_absent()
        print("All recorded private devices, images, and Kind nodes are absent.")

    def verify_resources_absent(self):
        self.require(not self.run(self.tool, "ps", "-aq", "--filter", f"label=io.x-k8s.kind.cluster={self.cluster}"), "Kind nodes remain.")
        for worker in self.state["workers"]:
            self.require(self.mapping(worker) is None and not self.loops(worker) and not Path(worker["image"]).exists(),
                         "A recorded private device or image remains.")

    def setup(self, args):
        self.require(not (self.directory / "owned").exists(), "An unfinished fixture exists. Run dev-teardown first.")
        env = os.environ
        env["KUBECONFIG"] = str(self.directory / "kubeconfig")
        env["KIND_BLOCK_STATE_DIR"] = str(self.directory)
        env["KIND_EXPERIMENTAL_PROVIDER"] = self.tool
        child = None
        try:
            child = subprocess.Popen(["bash", str(DEV / "setup.sh"), *args], start_new_session=True)
            status = child.wait()
            if status:
                raise FixtureError(f"Kind setup failed with status {status}.")
        except BaseException:
            if child is not None and child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=10)
            try:
                self.teardown()
            except (FixtureError, OSError, ValueError) as error:
                print(f"Setup cleanup failed. Retry dev-teardown with the same settings: {error}", file=sys.stderr)
            raise


def main():
    if command(["uname", "-s"]) == "Darwin":
        from kind_block_machine import main as machine_main
        return machine_main()

    def interrupted(signum, frame):
        signal.signal(signum, signal.SIG_IGN)
        raise FixtureError(f"Fixture operation interrupted by signal {signum}.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "teardown", "allocate", "install", "fault", "reclaim", "verify-clean"))
    parser.add_argument("--node")
    parser.add_argument("--namespace")
    parser.add_argument("--pod")
    parser.add_argument("--action")
    args, rest = parser.parse_known_args()
    fixture = Fixture()
    try:
        if args.command in ("fault", "reclaim"):
            fixture.deadline = time.monotonic() + (10 if args.command == "fault" else 120)
        if args.command in ("allocate", "install"):
            fixture.session()
            getattr(fixture, args.command)()
        else:
            with fixture.locked():
                os.environ["KIND_EXPERIMENTAL_PROVIDER"] = fixture.tool
                if args.command == "setup":
                    fixture.setup(rest[1:] if rest[:1] == ["--"] else rest)
                elif args.command == "fault":
                    fixture.fault(args.node, args.action)
                elif args.command == "reclaim":
                    fixture.require(args.node and args.namespace and args.pod, "NODE, NAMESPACE, and POD are required.")
                    fixture.reclaim(args.node, args.namespace, args.pod, args.action)
                else:
                    getattr(fixture, args.command.replace("-", "_"))()
    except (FixtureError, OSError, ValueError, KeyError) as error:
        print(f"Private Block fixture: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
