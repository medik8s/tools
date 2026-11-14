#!/usr/bin/env python3
"""Run Kind Block fixtures inside a rootful Podman Machine."""

import argparse
from contextlib import contextmanager
import fcntl
import io
import json
import os
from pathlib import Path
import re
import shlex
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit
import uuid


DEV = Path(__file__).resolve().parent
TOOLS = "/var/lib/medik8s/kind-block-tools"


class MachineError(RuntimeError):
    pass


def command(argv, *, input=None, timeout=30, capture=True, check=True):
    result = subprocess.run(
        argv, input=input, capture_output=capture, text=not isinstance(input, bytes),
        timeout=timeout,
    )
    if check and result.returncode:
        error = result.stderr or ""
        if isinstance(error, bytes):
            error = error.decode(errors="replace")
        raise MachineError(f"Command failed: {shlex.join(argv)}\n{error.strip()}")
    return result


def write_json(path, value):
    temporary = path.with_name(path.name + ".new")
    with temporary.open("w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, indent=2)
        stream.write("\n")
    temporary.replace(path)


class MachineFixture:
    def __init__(self):
        self.cluster = os.environ.get("MEDIK8S_CLUSTER_NAME", "medik8s-dev")
        self.mode = os.environ.get("KIND_BLOCK_MODE", "shared")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", self.cluster):
            raise MachineError("Invalid Kind cluster name.")
        if self.mode not in ("shared", "per-node"):
            raise MachineError("Use KIND_BLOCK_MODE=shared or per-node.")
        workers = os.environ.get("KIND_BLOCK_WORKERS")
        if self.mode == "shared" and workers is not None:
            raise MachineError("KIND_BLOCK_WORKERS requires KIND_BLOCK_MODE=per-node.")
        count = "3" if workers is None else workers
        if self.mode == "per-node" and (not re.fullmatch(r"[0-9]+", count) or int(count) < 3):
            raise MachineError("KIND_BLOCK_WORKERS must be an integer of at least 3.")
        if os.environ.get("CONTAINER_TOOL", "podman") != "podman":
            raise MachineError("The macOS Block wrapper requires CONTAINER_TOOL=podman.")
        if os.environ.get("SKIP_KIND") == "true":
            raise MachineError("Block fixtures require a new Kind cluster. --skip-kind is unsupported.")
        base = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        default = base / "medik8s/kind-block" / self.cluster
        requested = Path(os.environ.get("KIND_BLOCK_STATE_DIR", str(default)))
        if not requested.is_absolute() or requested.is_symlink():
            raise MachineError("KIND_BLOCK_STATE_DIR must be an absolute directory without a symlink.")
        self.directory = requested.resolve()
        self.record = self.directory / "machine.json"
        self.state = None
        self.machine = None

    @contextmanager
    def locked(self):
        self.directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        with (self.directory / "machine.lock").open("w") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise MachineError("Another Podman Machine fixture command holds this directory.")
            yield

    def inspect(self, name):
        machines = json.loads(command(["podman", "machine", "inspect", name]).stdout)
        if len(machines) != 1:
            raise MachineError("Expected one Podman Machine.")
        return machines[0]

    def select_machine(self):
        name = os.environ.get("KIND_BLOCK_MACHINE")
        if self.record.exists():
            self.state = json.loads(self.record.read_text())
            if (self.state["cluster"], self.state["mode"]) != (self.cluster, self.mode):
                raise MachineError("The recorded cluster or Block mode differs from these settings.")
            if name and name != self.state["machine"]:
                raise MachineError("KIND_BLOCK_MACHINE differs from the recorded machine.")
            name = self.state["machine"]
        if not name:
            machines = json.loads(command(["podman", "machine", "list", "--format", "json"]).stdout)
            running = [item for item in machines if item.get("Running")]
            candidates = running or machines
            if len(candidates) != 1:
                raise MachineError("Set KIND_BLOCK_MACHINE to the required Podman Machine name.")
            name = candidates[0]["Name"]
        self.machine = self.inspect(name)
        if self.state and self.state["created"] != self.machine["Created"]:
            raise MachineError("The Podman Machine was replaced. Preserve the fixture records for inspection.")
        if self.machine.get("Rootful") is not True:
            raise MachineError(f"Use a rootful Podman Machine: podman machine set --rootful {shlex.quote(name)}")
        if self.machine["State"] != "running":
            command(["podman", "machine", "start", name], timeout=180, capture=False)
            self.machine = self.inspect(name)

    def ssh(self):
        config = self.machine["SSHConfig"]
        return [
            "ssh", "-i", config["IdentityPath"], "-p", str(config["Port"]),
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={self.directory / 'known_hosts'}",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
            f"{config['RemoteUsername']}@127.0.0.1",
        ]

    def remote(self, argv, **kwargs):
        return command([*self.ssh(), shlex.join(argv)], **kwargs)

    def save(self):
        write_json(self.record, self.state)

    @property
    def guest(self):
        identifier = self.state["id"]
        if not re.fullmatch(r"[0-9a-f]{32}", identifier):
            raise MachineError("Invalid machine fixture identifier.")
        return f"/var/lib/medik8s/kind-block-machines/{identifier}"

    def environment(self):
        values = {
            "PATH": f"{TOOLS}/bin:{TOOLS}/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "CONTAINER_TOOL": "podman", "KUBECTL": "kubectl", "KIND_BLOCK_STORAGE": "true",
            "KIND_BLOCK_MODE": self.mode, "MEDIK8S_CLUSTER_NAME": self.cluster,
            "KIND_BLOCK_STATE_DIR": f"{self.guest}/state", "KUBECONFIG": f"{self.guest}/state/kubeconfig",
            "SKIP_REGISTRY": "true", "KEEP_REGISTRY": "true", "KIND_EXPERIMENTAL_PROVIDER": "podman",
            "KIND_BLOCK_SMOKE_ARTIFACTS": f"{self.guest}/artifacts",
        }
        for key in ("KIND_BLOCK_WORKERS", "KIND_HA", "KIND_POD_SUBNET", "KIND_SERVICE_SUBNET"):
            if key in os.environ:
                values[key] = os.environ[key]
        return ["sudo", "-n", "env", "-u", "CONTAINER_HOST", "-u", "CONTAINER_CONNECTION",
                "-u", "DOCKER_HOST", "-u", "DOCKER_CONTEXT", *[f"{key}={value}" for key, value in values.items()]]

    def guest_command(self, argv, **kwargs):
        script = f"cd {shlex.quote(self.guest + '/source')} && exec {shlex.join(argv)}"
        lock = f"/var/lib/medik8s/kind-block-machines/{self.cluster}.lock"
        return self.remote([*self.environment(), "flock", "-n", lock, "bash", "-c", script], **kwargs)

    def setup(self, args):
        if self.state and self.state["phase"] != "Cleaned":
            raise MachineError("An unfinished machine fixture exists. Run dev-teardown with the same settings.")
        if "--skip-kind" in args:
            raise MachineError("Block fixtures require a new Kind cluster. --skip-kind is unsupported.")
        self.state = {
            "id": uuid.uuid4().hex, "cluster": self.cluster, "mode": self.mode,
            "machine": self.machine["Name"], "created": self.machine["Created"], "phase": "Preparing",
        }
        self.save()
        try:
            self.remote(["sudo", "-n", "bash", "-s", "--", self.mode],
                        input=(DEV / "kind-block-machine-tools.sh").read_text(), timeout=900, capture=False)
            source = self.guest + "/source"
            self.remote(["sudo", "-n", "mkdir", "-p", source])
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w") as bundle:
                for path in sorted(DEV.rglob("*")):
                    if path.is_file() and not path.is_symlink() and not any(
                            part.startswith(".") or part == "__pycache__" for part in path.relative_to(DEV).parts):
                        bundle.add(path, arcname="dev/" + str(path.relative_to(DEV)), recursive=False)
            self.remote(["sudo", "-n", "tar", "-xf", "-", "-C", source], input=archive.getvalue())
            self.state["phase"] = "SettingUp"
            self.save()
            self.guest_command(["bash", "dev/setup.sh", *args], timeout=1500, capture=False)
            self.prepare_loop_nodes()
            self.connect()
            self.state["phase"] = "Ready"
            self.save()
        except BaseException:
            try:
                self.teardown()
            except (MachineError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                print(f"Setup cleanup failed. Retry dev-teardown with the same Block settings: {error}", file=sys.stderr)
            raise

    def prepare_loop_nodes(self):
        # Kubelet needs extra loop devices to hold raw Block volume references.
        script = r'''
set -euo pipefail
nodes=$(kind get nodes --name "$MEDIK8S_CLUSTER_NAME")
for node in $nodes; do
    case "$node" in "$MEDIK8S_CLUSTER_NAME"-worker*) ;; *) continue ;; esac
    podman exec "$node" bash -ceu '
        limit=255
        for entry in /sys/block/loop*; do
            index=${entry##*/loop}
            [[ $index =~ ^[0-9]+$ ]] || continue
            (( index + 256 <= limit )) || limit=$((index + 256))
        done
        parts=$(cat /sys/module/loop/parameters/max_part)
        shift=0
        while (( parts > 0 )); do
            shift=$((shift + 1))
            parts=$((parts >> 1))
        done
        for ((index=0; index<=limit; index++)); do
            path=/dev/loop$index
            minor=$((index << shift))
            if [[ -e "$path" || -L "$path" ]]; then
                [[ -b "$path" && ! -L "$path" ]] || exit 1
                expected=$(printf "7:%x" "$minor")
                [[ $(stat -c "%t:%T" "$path") == "$expected" ]] || exit 1
            else
                mknod -m 0600 "$path" b 7 "$minor"
            fi
        done
    '
done
'''
        self.guest_command(["bash", "-ceu", script], timeout=180, capture=False)

    def connect(self):
        result = self.guest_command(["kubectl", "config", "view", "--raw", "--flatten", "-o", "json"])
        config = json.loads(result.stdout)
        if config.get("current-context") != "kind-" + self.cluster or len(config.get("clusters", [])) != 1:
            raise MachineError("The guest kubeconfig does not identify the recorded Kind cluster.")
        cluster = config["clusters"][0]["cluster"]
        address = urlsplit(cluster["server"])
        if address.scheme != "https" or address.hostname not in ("127.0.0.1", "localhost") or not address.port:
            raise MachineError("Expected a loopback Kubernetes endpoint inside Podman Machine.")
        self.disconnect()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        control = Path(tempfile.mkdtemp(prefix="medik8s-ssh-", dir="/tmp")) / "control"
        self.state["tunnel"] = str(control)
        self.save()
        argv = self.ssh()
        command([*argv[:-1], "-M", "-S", str(control), "-fNT", "-o", "ExitOnForwardFailure=yes",
                 "-L", f"127.0.0.1:{port}:127.0.0.1:{address.port}", argv[-1]], capture=False)
        cluster["server"] = f"https://127.0.0.1:{port}"
        write_json(self.directory / "kubeconfig", config)
        print(f"Kubeconfig: {self.directory / 'kubeconfig'}")
        print(f"export KUBECONFIG={shlex.quote(str(self.directory / 'kubeconfig'))}")

    def disconnect(self):
        control = self.state.get("tunnel")
        if not control:
            return
        path = Path(control)
        if path.name != "control" or path.parent.parent != Path("/tmp") or not path.parent.name.startswith("medik8s-ssh-"):
            raise MachineError("Unexpected SSH control socket path.")
        if path.parent.exists():
            parent = path.parent.lstat()
            if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
                raise MachineError("The SSH control directory is not private to this user.")
        if path.exists():
            original = path.lstat()
            if not stat.S_ISSOCK(original.st_mode) or original.st_uid != os.getuid():
                raise MachineError("The SSH control path is not this user's socket.")
            argv = self.ssh()
            result = command([*argv[:-1], "-S", control, "-O", "exit", argv[-1]], check=False)
            deadline = time.monotonic() + 3
            while result.returncode == 0 and path.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            if path.exists():
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(1)
                    try:
                        probe.connect(str(path))
                    except (ConnectionRefusedError, FileNotFoundError):
                        if path.exists():
                            current = path.lstat()
                            if (current.st_dev, current.st_ino) != (original.st_dev, original.st_ino):
                                raise MachineError("The SSH control socket changed during cleanup.")
                            path.unlink()
                    else:
                        raise MachineError("The SSH tunnel is still active. Retry teardown or connect.")
        if path.parent.exists():
            path.parent.rmdir()
        self.state.pop("tunnel", None)
        self.save()

    def teardown(self):
        if self.state["phase"] == "Cleaned":
            self.disconnect()
            return
        if self.state["phase"] != "Preparing":
            self.guest_command(["bash", "dev/teardown.sh"], timeout=300, capture=False)
        self.disconnect()
        (self.directory / "kubeconfig").unlink(missing_ok=True)
        self.state["phase"] = "Cleaned"
        self.save()

    def forward(self, action, args):
        if action == "exec":
            if not args:
                raise MachineError("Specify a command after exec --.")
            self.guest_command(args, timeout=1500, capture=False)
        elif self.mode == "per-node":
            self.guest_command(["python3", "dev/kind_block_per_node.py", action, *args],
                               timeout=180, capture=False)
        elif action == "verify-clean":
            self.guest_command(["bash", "-ec", 'test ! -e "$KIND_BLOCK_STATE_DIR/owned" && '
                                'test ! -e "$KIND_BLOCK_STATE_DIR/block.img"'], capture=False)
        else:
            raise MachineError("Device faults and claim reclaim require KIND_BLOCK_MODE=per-node.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "teardown", "connect", "exec", "fault", "reclaim", "verify-clean"))
    args, rest = parser.parse_known_args(argv)
    rest = rest[1:] if rest[:1] == ["--"] else rest
    if args.command == "setup" and any(value in rest for value in ("-h", "--help")):
        parser.print_help()
        return 0
    if args.command in ("setup", "teardown") and "--name" in rest:
        index = rest.index("--name") + 1
        if index >= len(rest):
            parser.error("--name requires a cluster name")
        os.environ["MEDIK8S_CLUSTER_NAME"] = rest[index]
    if args.command == "setup" and "--ha" in rest:
        os.environ["KIND_HA"] = "true"
    try:
        if args.command == "setup" and "--skip-kind" in rest:
            raise MachineError("Block fixtures require a new Kind cluster. --skip-kind is unsupported.")
        fixture = MachineFixture()
        with fixture.locked():
            fixture.select_machine()
            if args.command == "setup":
                fixture.setup(rest)
            else:
                if fixture.state is None:
                    raise MachineError("No Podman Machine fixture is recorded in this state directory.")
                if args.command in ("teardown", "connect"):
                    getattr(fixture, args.command)()
                else:
                    fixture.forward(args.command, rest)
    except (MachineError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Podman Machine Block fixture: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
