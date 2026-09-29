#!/usr/bin/env python3
"""One-replacement Machine API simulator for disposable Podman or Docker Kind clusters."""
import argparse
import json
import os
import shlex
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


def container(*args, data=None):
    return run(os.environ.get("CONTAINER_TOOL", "podman"), *args, data=data)


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
    info = json.loads(container("inspect", name))[0]
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


def prepare(cluster, crd_dir):
    if get("namespace", NS):
        raise RuntimeError("MDR fixture already exists; use a fresh cluster")
    nodes = json.loads(kube("get", "nodes", "-o", "json"))["items"]
    workers = sorted((n for n in nodes if "node-role.kubernetes.io/control-plane" not in n["metadata"].get("labels", {})),
                     key=lambda n: n["metadata"]["name"])
    control_planes = [n for n in nodes if n not in workers]
    if len(workers) < 2 or len(control_planes) != 1 or not all(ready(n) for n in nodes):
        raise RuntimeError("Expected one Ready control plane and at least two Ready workers")
    for node in workers:
        name = node["metadata"]["name"]
        inspect_worker(name, cluster)
    for resource in ("machines", "machinesets"):
        filename = crd_dir / f"0000_10_machine-api_01_{resource}-Default.crd.yaml"
        kube("apply", "-f", str(filename))
        kube("wait", "--for=condition=Established", f"crd/{resource}.machine.openshift.io", "--timeout=60s")
    create({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}})
    owner = create({"apiVersion": "machine.openshift.io/v1beta1", "kind": "MachineSet",
                    "metadata": {"name": OWNER, "namespace": NS},
                    "spec": {"replicas": len(workers), "selector": {"matchLabels": {LABEL: cluster}},
                             "template": {"metadata": {"labels": {LABEL: cluster}},
                                          "spec": {"providerSpec": {"value": {}}}}}})
    owner_uid = owner["metadata"]["uid"]
    for node in workers:
        name = node["metadata"]["name"]
        create(machine_object(name, cluster, owner_uid))
        link_node(node, name)
    print(f"Prepared {len(workers)} active workers; replacement will be provisioned after deletion", flush=True)


def discover(cluster):
    owner = get("machinesets.machine.openshift.io", OWNER, NS)
    if not owner or owner["spec"]["replicas"] < 2:
        raise RuntimeError("Expected the prepared MachineSet with at least two replicas")
    control_planes = json.loads(kube("get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "json"))["items"]
    if len(control_planes) != 1:
        raise RuntimeError("Expected one control plane")
    cp = control_planes[0]["metadata"]["name"]
    labels = json.loads(container("inspect", cp))[0]["Config"]["Labels"]
    if labels.get("io.x-k8s.kind.cluster") != cluster or labels.get("io.x-k8s.kind.role") != "control-plane":
        raise RuntimeError("Kubeconfig does not match the named Kind cluster")
    machines = json.loads(kube("get", MACHINES, "-n", NS, "-l", f"{LABEL}={cluster}", "-o", "json"))["items"]
    if len(machines) != owner["spec"]["replicas"]:
        raise RuntimeError("Fixture Machine count must match MachineSet replicas")
    workers = []
    for machine in machines:
        name = machine["metadata"]["name"]
        ref = machine.get("status", {}).get("nodeRef", {})
        node = get("node", name)
        if (ref.get("name") != name or not ready(node) or ref.get("uid") != node["metadata"]["uid"]
                or node["metadata"].get("annotations", {}).get(ANNOTATION) != f"{NS}/{name}"):
            raise RuntimeError(f"Fixture Machine {name} must reference its Ready worker")
        info = inspect_worker(name, cluster)
        workers.append({"name": name, "uid": ref["uid"], "container_id": info["Id"],
                        "machine_uid": machine["metadata"]["uid"]})
    fixture = {"cluster": cluster, "owner_uid": owner["metadata"]["uid"],
               "control_plane": {"name": cp}, "workers": workers}
    pending_machine(fixture)
    print("Discovered fixture: " + json.dumps(fixture), flush=True)
    return fixture


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
    container("rm", "--force", "--volumes", info["Id"])
    # Query the daemon successfully; an inspect error alone would also hide daemon failures.
    if container("ps", "-aq", "--no-trunc", "--filter", f"id={info['Id']}").strip():
        raise RuntimeError("Victim container still exists")
    delete_node(entry["name"], entry["uid"])
    metadata = machine["metadata"]
    operations = [{"op": "test", "path": "/metadata/uid", "value": metadata["uid"]},
                  {"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
                  {"op": "replace", "path": "/metadata/finalizers",
                   "value": [f for f in metadata["finalizers"] if f != FINALIZER]}]
    kube("patch", MACHINES, entry["name"], "-n", NS, "--type=json", "-p", json.dumps(operations))
    wait_for("Machine deletion", lambda: get(MACHINES, entry["name"], NS) is None, 60)


def provision_worker(fixture, entry):
    cluster = fixture["cluster"]
    name = entry["name"] + "-replacement"
    source = next(worker for worker in fixture["workers"] if worker != entry)
    template = inspect_worker(source["name"], cluster, source["container_id"])
    provider = os.environ.get("KIND_EXPERIMENTAL_PROVIDER", Path(os.environ.get("CONTAINER_TOOL", "podman")).name)
    args = ["run", "--detach", "--tty", "--name", name, "--hostname", name,
            "--label", f"io.x-k8s.kind.cluster={cluster}", "--label", "io.x-k8s.kind.role=worker",
            "--privileged", "--network", "kind", "--cgroupns=private",
            "--tmpfs", "/tmp", "--tmpfs", "/run", "--volume", "/var",
            "--volume", "/lib/modules:/lib/modules:ro"]
    if provider == "podman":
        args += ["--env", "container=podman"]
    for mount in template.get("Mounts", []):
        if mount["Destination"] == "/dev/mapper":
            args += ["--volume", "/dev/mapper:/dev/mapper"]
    for env in template["Config"].get("Env", []):
        if env.split("=", 1)[0].lower() in ("http_proxy", "https_proxy", "no_proxy", "kind_experimental_containerd_snapshotter"):
            args += ["--env", env]
    container_id = container(*args, template["Config"]["Image"]).strip()
    print(f"Created replacement container {name}: {container_id}", flush=True)
    wait_for("replacement container boot", lambda: "Reached target" in container("logs", name), 60)
    info = inspect_worker(name, cluster, container_id)
    address = info["NetworkSettings"]["Networks"]["kind"]["IPAddress"]
    config = container("exec", source["name"], "cat", "/etc/containerd/config.toml")
    container("exec", "-i", name, "tee", "/etc/containerd/config.toml", data=config)
    registry = os.environ.get("MEDIK8S_REGISTRY_NAME", "kind-registry")
    port = os.environ.get("MEDIK8S_REGISTRY_PORT", "5000")
    directory = f"/etc/containerd/certs.d/{registry}:{port}"
    registry_config = container("exec", source["name"], "cat", directory + "/hosts.toml")
    container("exec", name, "mkdir", "-p", directory)
    container("exec", "-i", name, "tee", directory + "/hosts.toml", data=registry_config)
    registry_ip = container("exec", source["name"], "getent", "hosts", registry).split()[0]
    hosts = container("exec", name, "cat", "/etc/hosts")
    hosts = "\n".join(line for line in hosts.splitlines() if registry not in line.split()[1:])
    container("exec", "-i", name, "tee", "/etc/hosts", data=f"{hosts}\n{registry_ip} {registry}\n")
    container("exec", name, "systemctl", "restart", "containerd")
    cp = fixture["control_plane"]["name"]
    join = shlex.split(container("exec", cp, "kubeadm", "token", "create", "--ttl=20m", "--print-join-command"))
    config = {"apiVersion": "kubeadm.k8s.io/v1beta4", "kind": "JoinConfiguration",
              "discovery": {"bootstrapToken": {
                  "apiServerEndpoint": join[2], "token": join[join.index("--token") + 1],
                  "caCertHashes": [join[join.index("--discovery-token-ca-cert-hash") + 1]]}},
              "nodeRegistration": {"name": name, "criSocket": "unix:///run/containerd/containerd.sock",
                                   "kubeletExtraArgs": [{"name": "node-ip", "value": address},
                                                        {"name": "provider-id", "value": f"kind://{provider}/{cluster}/{name}"}]},
              "skipPhases": ["preflight"]}
    # Match Kind's kubeadm join: its container nodes cannot pass bare-host preflight checks.
    container("exec", "-i", name, "tee", "/kind/kubeadm.conf", data=json.dumps(config))
    try:
        output = container("exec", name, "kubeadm", "join", "--config=/kind/kubeadm.conf")
        print(output, flush=True)
    finally:
        container("exec", cp, "kubeadm", "token", "delete", config["discovery"]["bootstrapToken"]["token"].split(".")[0])


def cni_ready(name):
    node = get("node", name)
    if not ready(node) or not node.get("spec", {}).get("podCIDR"):
        return False
    value = container("exec", name, "sh", "-c", "cat /etc/cni/net.d/10-kindnet.conflist 2>/dev/null || true")
    if not value.strip():
        return False
    config = json.loads(value)
    subnets = [r["subnet"] for p in config["plugins"]
               for ranges in p.get("ipam", {}).get("ranges", []) for r in ranges]
    return node if node["spec"]["podCIDR"] in subnets else False


def verify_network(name, timeout):
    # Node Ready can precede kindnet and kube-proxy convergence.
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


def watch(cluster):
    fixture = discover(cluster)
    entry, machine = wait_for("Machine deletion request", lambda: pending_machine(fixture), 300)
    print(f"Deleting {entry['name']} for Machine UID {entry['machine_uid']}", flush=True)
    remove_machine(entry, machine, fixture)
    replacement_deadline = time.monotonic() + 900
    replacement_name = entry["name"] + "-replacement"
    create(machine_object(replacement_name, cluster, fixture["owner_uid"]))
    print(f"Provisioning fresh worker {replacement_name}", flush=True)
    provision_worker(fixture, entry)
    replacement = wait_for("replacement Ready and CNI subnet convergence", lambda: cni_ready(replacement_name),
                           replacement_deadline - time.monotonic())
    verify_network(replacement_name, min(180, replacement_deadline - time.monotonic()))
    link_node(replacement, replacement_name)
    print("Replacement network verified and worker published", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "watch"])
    parser.add_argument("--name", required=True)
    parser.add_argument("--crd-dir", type=Path)
    args = parser.parse_args()
    try:
        container("info")
        if kube("config", "current-context").strip() != f"kind-{args.name}":
            raise RuntimeError("Use the named Kind cluster's isolated kubeconfig")
        if args.action == "prepare":
            if not args.crd_dir:
                raise RuntimeError("prepare requires --crd-dir")
            prepare(args.name, args.crd_dir)
        else:
            watch(args.name)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"MDR simulator failed: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
