#!/usr/bin/env python3
"""One-replacement Machine API simulator for disposable Docker Kind clusters."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


LABEL = "medik8s.io/kind-mdr"
FINALIZER = "medik8s.io/kind-mdr-container"
ANNOTATION = "machine.openshift.io/machine"
WORKER = "node-role.kubernetes.io/worker"
NS = "kind-mdr-machines"
OWNER = "kind-workers"
MACHINES = "machines.machine.openshift.io"


def run(*args, data=None):
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args[:4])}: {result.stderr.strip()}")
    return result.stdout


def kube(*args, data=None):
    return run(os.environ.get("KUBECTL", "kubectl"), "--request-timeout=30s", *args, data=data)


def docker(*args):
    return run(os.environ.get("CONTAINER_TOOL", "docker"), *args)


def get(resource, name, namespace=None):
    args = ["get", resource, name, "--ignore-not-found", "-o", "json"]
    if namespace:
        args += ["-n", namespace]
    value = kube(*args)
    return json.loads(value) if value.strip() else None


def create(obj):
    return json.loads(kube("create", "-f", "-", "-o", "json", data=json.dumps(obj)))


def patch(resource, name, value, namespace=None, status=False):
    args = ["patch", resource, name, "--type=merge", "-p", json.dumps(value)]
    if namespace:
        args += ["-n", namespace]
    if status:
        args += ["--subresource=status"]
    kube(*args)


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def wait_for(message, predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(2)
    raise RuntimeError(f"Timed out: {message}")


def ready(node):
    return node and any(c["type"] == "Ready" and c["status"] == "True"
                        for c in node.get("status", {}).get("conditions", []))


def inspect_worker(name, cluster, container_id=None):
    info = json.loads(docker("inspect", name))[0]
    labels = info["Config"].get("Labels", {})
    if labels.get("io.x-k8s.kind.cluster") != cluster or labels.get("io.x-k8s.kind.role") != "worker":
        raise RuntimeError(f"Refusing non-worker or foreign container: {name}")
    if container_id and info["Id"] != container_id:
        raise RuntimeError(f"Container identity changed: {name}")
    return info


def delete_node(name, uid):
    # A replaced Node with the same name must not be removed by a stale fixture.
    options = {"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": {"uid": uid}}
    kube("delete", f"--raw=/api/v1/nodes/{name}", "-f", "-", data=json.dumps(options))
    wait_for(f"Node {name} deletion", lambda: get("node", name) is None, 60)


def machine_object(name, cluster, owner_uid):
    return {"apiVersion": "machine.openshift.io/v1beta1", "kind": "Machine",
            "metadata": {"name": name, "namespace": NS, "labels": {LABEL: cluster},
                         "finalizers": [FINALIZER], "ownerReferences": [{
                             "apiVersion": "machine.openshift.io/v1beta1", "kind": "MachineSet",
                             "name": OWNER, "uid": owner_uid, "controller": True}]},
            "spec": {"providerID": f"kind://{cluster}/{name}", "providerSpec": {"value": {}}}}


def link_node(node, machine):
    name = node["metadata"]["name"]
    patch(MACHINES, machine, {"status": {"nodeRef": {
        "apiVersion": "v1", "kind": "Node", "name": name, "uid": node["metadata"]["uid"]}}}, NS, True)
    patch("node", name, {"metadata": {"uid": node["metadata"]["uid"],
                                     "annotations": {ANNOTATION: f"{NS}/{machine}"},
                                     "labels": {WORKER: ""}}})


def prepare(cluster, state, crd_dir):
    if (state / "fixture.json").exists() or get("namespace", NS):
        raise RuntimeError("MDR fixture already exists; use a fresh cluster and state directory")
    nodes = json.loads(kube("get", "nodes", "-o", "json"))["items"]
    workers = sorted((n for n in nodes if "node-role.kubernetes.io/control-plane" not in n["metadata"].get("labels", {})),
                     key=lambda n: n["metadata"]["name"])
    control_planes = [n for n in nodes if n not in workers]
    if len(workers) != 3 or len(control_planes) != 1 or not all(ready(n) for n in nodes):
        raise RuntimeError("Expected one Ready control plane and three Ready workers")
    entries = []
    for node in workers:
        name = node["metadata"]["name"]
        info = inspect_worker(name, cluster)
        entries.append({"name": name, "uid": node["metadata"]["uid"], "container_id": info["Id"]})
    spare = entries.pop()
    kube("drain", spare["name"], "--ignore-daemonsets", "--delete-emptydir-data", "--timeout=90s")
    docker("stop", spare["container_id"])
    delete_node(spare["name"], spare["uid"])
    for resource in ("machines", "machinesets"):
        filename = crd_dir / f"0000_10_machine-api_01_{resource}-Default.crd.yaml"
        kube("apply", "-f", str(filename))
        kube("wait", "--for=condition=Established", f"crd/{resource}.machine.openshift.io", "--timeout=60s")
    create({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}})
    owner = create({"apiVersion": "machine.openshift.io/v1beta1", "kind": "MachineSet",
                    "metadata": {"name": OWNER, "namespace": NS},
                    "spec": {"replicas": 2, "selector": {"matchLabels": {LABEL: cluster}},
                             "template": {"metadata": {"labels": {LABEL: cluster}},
                                          "spec": {"providerSpec": {"value": {}}}}}})
    owner_uid = owner["metadata"]["uid"]
    for entry in entries:
        machine = create(machine_object(entry["name"], cluster, owner_uid))
        entry["machine_uid"] = machine["metadata"]["uid"]
        link_node(get("node", entry["name"]), entry["name"])
    fixture = {"cluster": cluster, "namespace": NS, "owner_uid": owner_uid,
               "control_plane": {"name": control_planes[0]["metadata"]["name"],
                                 "uid": control_planes[0]["metadata"]["uid"]},
               "workers": entries, "spare": spare}
    save(state / "fixture.json", fixture)
    print("Prepared two active workers and one stopped spare", flush=True)


def pending_machine(fixture):
    for entry in fixture["workers"]:
        machine = get(MACHINES, entry["name"], NS)
        if not machine:
            raise RuntimeError("Fixture Machine disappeared without simulator finalization")
        metadata = machine["metadata"]
        owners = metadata.get("ownerReferences", [])
        if (metadata["uid"] != entry["machine_uid"] or metadata.get("labels", {}).get(LABEL) != fixture["cluster"]
                or FINALIZER not in metadata.get("finalizers", []) or len(owners) != 1
                or owners[0].get("uid") != fixture["owner_uid"] or not owners[0].get("controller")):
            raise RuntimeError("Fixture Machine identity, ownership or finalizer changed")
        if metadata.get("deletionTimestamp"):
            return entry, machine
    return None


def remove_machine(entry, machine, fixture):
    info = inspect_worker(entry["name"], fixture["cluster"], entry["container_id"])
    node = get("node", entry["name"])
    if not node or node["metadata"]["uid"] != entry["uid"]:
        raise RuntimeError("Original Node identity changed")
    docker("rm", "--force", info["Id"])
    # Query the daemon successfully; an inspect error alone would also hide daemon failures.
    if docker("ps", "-aq", "--no-trunc", "--filter", f"id={info['Id']}").strip():
        raise RuntimeError("Victim container still exists")
    delete_node(entry["name"], entry["uid"])
    metadata = machine["metadata"]
    operations = [{"op": "test", "path": "/metadata/uid", "value": metadata["uid"]},
                  {"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
                  {"op": "replace", "path": "/metadata/finalizers",
                   "value": [f for f in metadata["finalizers"] if f != FINALIZER]}]
    kube("patch", MACHINES, entry["name"], "-n", NS, "--type=json", "-p", json.dumps(operations))
    wait_for("Machine deletion", lambda: get(MACHINES, entry["name"], NS) is None, 60)


def cni_ready(name):
    node = get("node", name)
    if not ready(node) or not node.get("spec", {}).get("podCIDR"):
        return False
    config = json.loads(docker("exec", name, "cat", "/etc/cni/net.d/10-kindnet.conflist"))
    subnets = [r["subnet"] for p in config["plugins"]
               for ranges in p.get("ipam", {}).get("ranges", []) for r in ranges]
    return node if node["spec"]["podCIDR"] in subnets else False


def verify_network(name, timeout):
    # Node Ready can precede kindnet and kube-proxy convergence after Node recreation.
    command = "nslookup kubernetes.default.svc.cluster.local && wget -S -O /dev/null --no-check-certificate https://kubernetes.default.svc 2>&1 | grep -E 'HTTP/.* (200|401|403)'"
    create({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "replacement-network", "namespace": NS},
            "spec": {"nodeName": name, "restartPolicy": "Never", "containers": [{
                "name": "probe", "image": "busybox:1.37", "command": ["sh", "-c",
                    f"for i in $(seq 1 30); do ({command}) && exit 0; sleep 2; done; exit 1"]}]}})
    def succeeded():
        phase = get("pod", "replacement-network", NS)["status"]["phase"]
        if phase == "Failed":
            raise RuntimeError("Replacement networking failed; see replacement-network pod logs")
        return phase == "Succeeded"
    wait_for("replacement pod networking", succeeded, timeout)


def watch(cluster, state):
    fixture = json.loads((state / "fixture.json").read_text())
    if fixture["cluster"] != cluster or (state / "ready").exists():
        raise RuntimeError("Wrong cluster or reused watcher state; start a fresh run")
    cp = get("node", fixture["control_plane"]["name"])
    if not cp or cp["metadata"]["uid"] != fixture["control_plane"]["uid"]:
        raise RuntimeError("Kubeconfig does not match the prepared cluster")
    spare = fixture["spare"]
    info = inspect_worker(spare["name"], cluster, spare["container_id"])
    if info["State"]["Running"] or get("node", spare["name"]):
        raise RuntimeError("Spare must be stopped and absent from Kubernetes")
    pending_machine(fixture)
    save(state / "ready", {"cluster": cluster})
    entry, machine = wait_for("Machine deletion request", lambda: pending_machine(fixture), 300)
    print(f"Deleting {entry['name']} for Machine UID {entry['machine_uid']}", flush=True)
    remove_machine(entry, machine, fixture)
    save(state / "deleted.json", entry)
    replacement_deadline = time.monotonic() + 900
    gate = state / f"replace-{entry['machine_uid']}"
    wait_for("test replacement release", gate.exists, replacement_deadline - time.monotonic())
    replacement_name = spare["name"] + "-replacement"
    create(machine_object(replacement_name, cluster, fixture["owner_uid"]))
    inspect_worker(spare["name"], cluster, spare["container_id"])
    docker("start", spare["container_id"])
    replacement = wait_for("replacement Ready and CNI subnet convergence", lambda: cni_ready(spare["name"]),
                           min(300, replacement_deadline - time.monotonic()))
    if replacement["metadata"]["uid"] == spare["uid"]:
        raise RuntimeError("Spare did not register a new Node")
    verify_network(spare["name"], min(180, replacement_deadline - time.monotonic()))
    link_node(replacement, replacement_name)
    save(state / "complete.json", {"deleted": entry, "replacement": spare["name"], "machine": replacement_name})
    print("Replacement network verified and worker published", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "watch"])
    parser.add_argument("--name", required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--crd-dir", type=Path)
    args = parser.parse_args()
    args.state_dir.mkdir(parents=True, exist_ok=True)
    try:
        if json.loads(docker("version", "--format", "{{json .Server}}"))["Platform"]["Name"].lower().find("podman") >= 0:
            raise RuntimeError("MDR Kind simulation supports Docker only")
        if kube("config", "current-context").strip() != f"kind-{args.name}":
            raise RuntimeError("Use the named Kind cluster's isolated kubeconfig")
        if args.action == "prepare":
            if not args.crd_dir:
                raise RuntimeError("prepare requires --crd-dir")
            prepare(args.name, args.state_dir, args.crd_dir)
        else:
            watch(args.name, args.state_dir)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        save(args.state_dir / "error.json", {"error": str(error)})
        print(f"MDR simulator failed: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
