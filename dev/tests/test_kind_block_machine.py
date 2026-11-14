"""Check Podman Machine operations without a VM, SSH, or root access."""

import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch


DEV = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("kind_block_machine", DEV / "kind_block_machine.py")
machine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(machine)


class MachineFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kind-block-machine-test-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state_dir = self.root / "state"
        self.state_dir.mkdir()
        self.environment = patch.dict(os.environ, {
            "MEDIK8S_CLUSTER_NAME": "block-test",
            "KIND_BLOCK_STATE_DIR": str(self.state_dir),
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.vm = {
            "Name": "test-machine", "Created": "2026-11-01T12:00:00Z",
            "Rootful": True, "State": "running",
            "SSHConfig": {"IdentityPath": "/tmp/test identity", "Port": 12345,
                          "RemoteUsername": "core"},
        }
        self.state = {
            "id": "a" * 32, "cluster": "block-test", "mode": "shared",
            "machine": "test-machine", "created": self.vm["Created"], "phase": "Ready",
        }

    def fixture(self, *, recorded=False):
        fixture = machine.MachineFixture()
        fixture.machine = copy.deepcopy(self.vm)
        if recorded:
            fixture.state = copy.deepcopy(self.state)
            fixture.save()
        return fixture

    @staticmethod
    def result(value="", returncode=0):
        return subprocess.CompletedProcess([], returncode, stdout=value, stderr="")

    def test_selects_the_only_running_machine(self):
        fixture = self.fixture()
        machines = [{"Name": "stopped", "Running": False},
                    {"Name": self.vm["Name"], "Running": True}]
        with patch.object(machine, "command", side_effect=[
                self.result(json.dumps(machines)), self.result(json.dumps([self.vm]))]) as run:
            fixture.select_machine()
        self.assertEqual(fixture.machine, self.vm)
        self.assertEqual(run.call_args_list[-1].args[0],
                         ["podman", "machine", "inspect", "test-machine"])

    def test_rejects_ambiguous_machine_selection(self):
        fixture = self.fixture()
        machines = [{"Name": "one", "Running": True}, {"Name": "two", "Running": True}]
        with patch.object(machine, "command", return_value=self.result(json.dumps(machines))) as run:
            with self.assertRaisesRegex(machine.MachineError, "KIND_BLOCK_MACHINE"):
                fixture.select_machine()
        self.assertEqual(run.call_count, 1)

    def test_requires_rootful_machine_before_start(self):
        fixture = self.fixture()
        vm = dict(self.vm, Rootful=False, State="stopped")
        with patch.dict(os.environ, {"KIND_BLOCK_MACHINE": vm["Name"]}):
            with patch.object(machine, "command", return_value=self.result(json.dumps([vm]))) as run:
                with self.assertRaisesRegex(machine.MachineError, "rootful"):
                    fixture.select_machine()
        self.assertEqual(run.call_count, 1)

    def test_starts_the_explicit_machine(self):
        fixture = self.fixture()
        stopped = dict(self.vm, State="stopped")
        with patch.dict(os.environ, {"KIND_BLOCK_MACHINE": self.vm["Name"]}):
            with patch.object(machine, "command", side_effect=[
                    self.result(json.dumps([stopped])), self.result(),
                    self.result(json.dumps([self.vm]))]) as run:
                fixture.select_machine()
        self.assertIn(["podman", "machine", "start", "test-machine"],
                      [call.args[0] for call in run.call_args_list])

    def test_replaced_machine_does_not_start_or_change_records(self):
        fixture = self.fixture(recorded=True)
        original = fixture.record.read_bytes()
        replacement = dict(self.vm, Created="2026-11-12T12:00:00Z", State="stopped")
        with patch.object(machine, "command", return_value=self.result(json.dumps([replacement]))) as run:
            with self.assertRaisesRegex(machine.MachineError, "replaced"):
                fixture.select_machine()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(fixture.record.read_bytes(), original)

    def test_recorded_machine_setting_must_match(self):
        fixture = self.fixture(recorded=True)
        with patch.dict(os.environ, {"KIND_BLOCK_MACHINE": "another-machine"}):
            with patch.object(machine, "command") as run:
                with self.assertRaisesRegex(machine.MachineError, "differs"):
                    fixture.select_machine()
        run.assert_not_called()

    def test_rejects_malformed_machine_json(self):
        with patch.object(machine, "command", return_value=self.result("notice\n[]")):
            with self.assertRaises(json.JSONDecodeError):
                self.fixture().select_machine()

    def test_rejects_relative_and_symlink_state_directories(self):
        link = self.root / "state-link"
        link.symlink_to(self.state_dir, target_is_directory=True)
        for directory in ("relative-state", str(link)):
            with self.subTest(directory=directory):
                with patch.dict(os.environ, {"KIND_BLOCK_STATE_DIR": directory}):
                    with self.assertRaisesRegex(machine.MachineError, "absolute directory"):
                        machine.MachineFixture()

    def test_rejects_invalid_settings_before_commands(self):
        invalid = ({"MEDIK8S_CLUSTER_NAME": "../other"}, {"KIND_BLOCK_MODE": "invalid"},
                   {"KIND_BLOCK_WORKERS": "3"}, {"CONTAINER_TOOL": "docker"},
                   {"KIND_BLOCK_MODE": "per-node", "KIND_BLOCK_WORKERS": "2"},
                   {"KIND_BLOCK_MODE": "per-node", "KIND_BLOCK_WORKERS": ""},
                   {"KIND_BLOCK_MODE": "per-node", "KIND_BLOCK_WORKERS": "3;false"})
        with patch.object(machine, "command") as run:
            for values in invalid:
                with self.subTest(values=values), patch.dict(os.environ, values):
                    with self.assertRaises(machine.MachineError):
                        machine.MachineFixture()
        run.assert_not_called()

    def test_skip_kind_fails_before_machine_inspection(self):
        with patch.dict(os.environ, {"CONTAINER_TOOL": "docker"}):
            with patch.object(machine, "command") as run, patch("sys.stderr", new_callable=io.StringIO) as error:
                self.assertEqual(machine.main(["setup", "--skip-kind"]), 1)
        self.assertIn("--skip-kind", error.getvalue())
        run.assert_not_called()

    def test_guest_identifier_cannot_change_guest_path(self):
        fixture = self.fixture(recorded=True)
        fixture.state["id"] = "../../other"
        with self.assertRaisesRegex(machine.MachineError, "identifier"):
            fixture.guest_command(["true"])

    def test_guest_environment_selects_local_podman_for_both_modes(self):
        for mode in ("shared", "per-node"):
            with self.subTest(mode=mode), patch.dict(os.environ, {
                    "KIND_BLOCK_MODE": mode, "CONTAINER_HOST": "ssh://host",
                    "CONTAINER_CONNECTION": "remote", "DOCKER_HOST": "ssh://docker",
                    "DOCKER_CONTEXT": "remote", "KUBECONFIG": "/host/config"}):
                fixture = self.fixture(recorded=True)
                argv = fixture.environment()
                for key in ("CONTAINER_HOST", "CONTAINER_CONNECTION", "DOCKER_HOST", "DOCKER_CONTEXT"):
                    self.assertIn(["-u", key], [argv[i:i + 2] for i in range(len(argv) - 1)])
                    self.assertFalse(any(value.startswith(key + "=") for value in argv))
                self.assertIn("CONTAINER_TOOL=podman", argv)
                self.assertIn("KIND_BLOCK_MODE=" + mode, argv)
                self.assertIn("KUBECONFIG=" + fixture.guest + "/state/kubeconfig", argv)

    def test_guest_command_preserves_shell_arguments(self):
        fixture = self.fixture(recorded=True)
        arguments = ["printf", "%s", "space value", "$(touch /tmp/not-created)", "quote'value", "line\nbreak"]
        with patch.object(machine, "command", return_value=self.result()) as run:
            fixture.guest_command(arguments)
        ssh_argv = run.call_args.args[0]
        self.assertEqual(ssh_argv[-2], "core@127.0.0.1")
        remote_argv = shlex.split(ssh_argv[-1])
        self.assertEqual(remote_argv[-2], "-c")
        script = remote_argv[-1]
        self.assertEqual(shlex.split(script.split(" && exec ", 1)[1]), arguments)
        self.assertIn("-n", remote_argv)

    def test_guest_cleanup_preserves_existing_registry(self):
        fixture = self.fixture(recorded=True)
        with patch.dict(os.environ, {"KEEP_REGISTRY": "false"}):
            self.assertIn("KEEP_REGISTRY=true", fixture.environment())

    def test_setup_stages_regular_sources_and_excludes_links(self):
        fixture = self.fixture()
        source = self.root / "dev"
        source.mkdir()
        (source / "setup.sh").write_text("exit 0\n")
        bootstrap = "echo prepare\n"
        (source / "kind-block-machine-tools.sh").write_text(bootstrap)
        (source / "linked.sh").symlink_to(source / "setup.sh")
        (source / ".secret").write_text("hidden")
        (source / "__pycache__").mkdir()
        (source / "__pycache__" / "cached.pyc").write_bytes(b"cache")
        with patch.object(machine, "DEV", source), patch.object(fixture, "remote") as remote:
            with patch.object(fixture, "guest_command") as guest, patch.object(fixture, "connect"):
                with patch.object(fixture, "prepare_loop_nodes") as prepare:
                    fixture.setup(["--name", "block-test"])
        bootstrap_call = remote.call_args_list[0]
        self.assertEqual(bootstrap_call.args[0], ["sudo", "-n", "bash", "-s", "--", "shared"])
        self.assertEqual(bootstrap_call.kwargs["input"], bootstrap)
        archive = next(call.kwargs["input"] for call in remote.call_args_list
                       if isinstance(call.kwargs.get("input"), bytes))
        with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
            self.assertEqual(set(bundle.getnames()), {"dev/setup.sh", "dev/kind-block-machine-tools.sh"})
            self.assertTrue(all(member.isfile() for member in bundle.getmembers()))
        self.assertEqual(guest.call_args_list[0].args[0], ["bash", "dev/setup.sh", "--name", "block-test"])
        prepare.assert_called_once()
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "Ready")

    def test_failed_guest_setup_preserves_record_for_teardown(self):
        fixture = self.fixture()
        primary = machine.MachineError("setup failed")
        with patch.object(fixture, "remote"), patch.object(fixture, "connect") as connect:
            with patch.object(fixture, "guest_command", side_effect=[
                    primary, machine.MachineError("cleanup failed")]):
                with self.assertRaisesRegex(machine.MachineError, "setup failed") as caught:
                    fixture.setup([])
        self.assertIs(caught.exception, primary)
        connect.assert_not_called()
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "SettingUp")
        with patch.object(fixture, "guest_command") as guest:
            fixture.teardown()
        self.assertEqual(guest.call_args.args[0], ["bash", "dev/teardown.sh"])
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "Cleaned")

    def test_setup_failure_runs_cleanup_and_preserves_primary_error(self):
        fixture = self.fixture()
        with patch.object(fixture, "remote"), patch.object(fixture, "connect") as connect:
            with patch.object(fixture, "guest_command", side_effect=[
                    machine.MachineError("primary setup failure"), self.result()]) as guest:
                with self.assertRaisesRegex(machine.MachineError, "primary setup failure"):
                    fixture.setup([])
        connect.assert_not_called()
        self.assertEqual(guest.call_args_list[-1].args[0], ["bash", "dev/teardown.sh"])
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "Cleaned")

    def test_connection_failure_runs_guest_cleanup(self):
        fixture = self.fixture()
        with patch.object(fixture, "remote"), patch.object(fixture, "guest_command") as guest:
            with patch.object(fixture, "connect", side_effect=machine.MachineError("tunnel failed")):
                with self.assertRaisesRegex(machine.MachineError, "tunnel failed"):
                    fixture.setup([])
        self.assertEqual(guest.call_args_list[-1].args[0], ["bash", "dev/teardown.sh"])
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "Cleaned")

    def test_loop_preparation_failure_runs_guest_cleanup(self):
        fixture = self.fixture()
        with patch.object(fixture, "remote"), patch.object(fixture, "guest_command") as guest:
            with patch.object(fixture, "prepare_loop_nodes", side_effect=machine.MachineError("loop nodes failed")):
                with patch.object(fixture, "connect") as connect:
                    with self.assertRaisesRegex(machine.MachineError, "loop nodes failed"):
                        fixture.setup([])
        connect.assert_not_called()
        self.assertEqual(guest.call_args_list[-1].args[0], ["bash", "dev/teardown.sh"])
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "Cleaned")

    def test_loop_preparation_changes_only_this_clusters_workers(self):
        fixture = self.fixture(recorded=True)
        with patch.object(fixture, "guest_command") as guest:
            fixture.prepare_loop_nodes()
        argv = guest.call_args.args[0]
        startup = self.root / "loop-node-env"
        calls = self.root / "loop-node-calls"
        startup.write_text('''
kind() {
    printf '%s\\n' block-test-control-plane block-test-worker block-test-worker2 other-worker
}
podman() { printf '%s\\n' "$2" >> "$LOOP_NODE_CALLS"; }
''')
        result = subprocess.run(argv, env={"BASH_ENV": str(startup), "LOOP_NODE_CALLS": str(calls),
                                          "MEDIK8S_CLUSTER_NAME": "block-test"},
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.read_text().splitlines(), ["block-test-worker", "block-test-worker2"])

    def test_preparation_failure_does_not_run_guest_cleanup(self):
        fixture = self.fixture()
        with patch.object(fixture, "remote", side_effect=machine.MachineError("bootstrap failed")):
            with self.assertRaisesRegex(machine.MachineError, "bootstrap failed"):
                fixture.setup([])
        self.assertEqual(json.loads(fixture.record.read_text())["phase"], "Cleaned")
        with patch.object(fixture, "guest_command") as guest:
            fixture.teardown()
        guest.assert_not_called()
        self.assertEqual(fixture.state["phase"], "Cleaned")

    def test_cleanup_failure_preserves_tunnel_and_allows_retry(self):
        fixture = self.fixture(recorded=True)
        fixture.state["tunnel"] = "/tmp/medik8s-ssh-test/control"
        fixture.save()
        kubeconfig = fixture.directory / "kubeconfig"
        kubeconfig.write_text("keep credentials")
        with patch.object(fixture, "disconnect") as disconnect:
            with patch.object(fixture, "guest_command", side_effect=machine.MachineError("cleanup failed")):
                with self.assertRaisesRegex(machine.MachineError, "cleanup failed"):
                    fixture.teardown()
            disconnect.assert_not_called()
            self.assertEqual(json.loads(fixture.record.read_text())["tunnel"], fixture.state["tunnel"])
            self.assertTrue(kubeconfig.exists())
            with patch.object(fixture, "guest_command"):
                fixture.teardown()
            disconnect.assert_called_once()
        self.assertEqual(fixture.state["phase"], "Cleaned")
        self.assertFalse(kubeconfig.exists())

    def kubeconfig(self, server="https://127.0.0.1:6443"):
        return {"current-context": "kind-block-test", "clusters": [
            {"name": "kind-block-test", "cluster": {"server": server, "certificate-authority-data": "test"}}]}

    def test_connect_uses_loopback_and_private_kubeconfig(self):
        fixture = self.fixture(recorded=True)
        listener = Mock()
        listener.__enter__ = Mock(return_value=listener)
        listener.__exit__ = Mock(return_value=False)
        listener.getsockname.return_value = ("127.0.0.1", 45678)
        control_dir = self.root / "medik8s-ssh-test"
        control_dir.mkdir()
        with patch.object(fixture, "guest_command", return_value=self.result(json.dumps(self.kubeconfig()))):
            with patch.object(machine.socket, "socket", return_value=listener):
                with patch.object(machine.tempfile, "mkdtemp", return_value=str(control_dir)):
                    with patch.object(machine, "command", return_value=self.result()) as run:
                        fixture.connect()
        listener.bind.assert_called_once_with(("127.0.0.1", 0))
        self.assertIn("127.0.0.1:45678:127.0.0.1:6443", run.call_args.args[0])
        path = fixture.directory / "kubeconfig"
        config = json.loads(path.read_text())
        self.assertEqual(config["clusters"][0]["cluster"]["server"], "https://127.0.0.1:45678")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(fixture.record.stat().st_mode), 0o600)

    def test_connect_rejects_unrelated_or_public_kubeconfig(self):
        fixture = self.fixture(recorded=True)
        wrong_context = self.kubeconfig()
        wrong_context["current-context"] = "kind-other"
        configs = [wrong_context, self.kubeconfig("https://10.0.0.1:6443"),
                   self.kubeconfig("http://127.0.0.1:6443")]
        for config in configs:
            with self.subTest(config=config):
                with patch.object(fixture, "guest_command", return_value=self.result(json.dumps(config))):
                    with patch.object(machine, "command") as run:
                        with self.assertRaises(machine.MachineError):
                            fixture.connect()
                    run.assert_not_called()
        self.assertFalse((fixture.directory / "kubeconfig").exists())

    def test_disconnect_failure_preserves_record(self):
        fixture = self.fixture(recorded=True)
        control_dir = Path(tempfile.mkdtemp(prefix="medik8s-ssh-", dir="/tmp"))
        self.addCleanup(lambda: control_dir.rmdir() if control_dir.exists() else None)
        control = control_dir / "control"
        self.addCleanup(lambda: control.unlink(missing_ok=True))
        control.touch()
        control.chmod(0o600)
        fixture.state["tunnel"] = str(control)
        fixture.save()
        with patch.object(machine.stat, "S_ISSOCK", return_value=True):
            with patch.object(machine.socket, "socket"), patch.object(
                    machine, "command", return_value=self.result(returncode=1)):
                with self.assertRaisesRegex(machine.MachineError, "still active"):
                    fixture.disconnect()
        self.assertEqual(json.loads(fixture.record.read_text())["tunnel"], str(control))
        def close_tunnel(*args, **kwargs):
            control.unlink()
            return self.result()
        with patch.object(machine.stat, "S_ISSOCK", return_value=True):
            with patch.object(machine, "command", side_effect=close_tunnel):
                fixture.disconnect()
        self.assertNotIn("tunnel", json.loads(fixture.record.read_text()))
        self.assertFalse(control_dir.exists())

    def test_disconnect_removes_only_a_stale_owned_socket(self):
        fixture = self.fixture(recorded=True)
        control_dir = Path(tempfile.mkdtemp(prefix="medik8s-ssh-", dir="/tmp"))
        self.addCleanup(lambda: control_dir.rmdir() if control_dir.exists() else None)
        control = control_dir / "control"
        self.addCleanup(lambda: control.unlink(missing_ok=True))
        control.touch()
        control.chmod(0o600)
        fixture.state["tunnel"] = str(control)
        fixture.save()
        with patch.object(machine.stat, "S_ISSOCK", return_value=True):
            with patch.object(machine.socket, "socket") as socket_factory:
                socket_factory.return_value.__enter__.return_value.connect.side_effect = ConnectionRefusedError
                with patch.object(machine, "command", return_value=self.result(returncode=1)):
                    fixture.disconnect()
        self.assertFalse(control.exists())
        self.assertFalse(control_dir.exists())
        self.assertNotIn("tunnel", json.loads(fixture.record.read_text()))

    def test_disconnect_rejects_unowned_control_path(self):
        fixture = self.fixture(recorded=True)
        fixture.state["tunnel"] = str(self.root / "other" / "control")
        with patch.object(machine, "command") as run:
            with self.assertRaisesRegex(machine.MachineError, "control socket path"):
                fixture.disconnect()
        run.assert_not_called()

    def test_disconnect_rejects_public_directory_and_regular_file(self):
        fixture = self.fixture(recorded=True)
        control_dir = Path(tempfile.mkdtemp(prefix="medik8s-ssh-", dir="/tmp"))
        self.addCleanup(lambda: control_dir.rmdir() if control_dir.exists() else None)
        control = control_dir / "control"
        control.touch()
        self.addCleanup(lambda: control.unlink(missing_ok=True))
        fixture.state["tunnel"] = str(control)
        with patch.object(machine, "command") as run:
            control_dir.chmod(0o755)
            with self.assertRaisesRegex(machine.MachineError, "private"):
                fixture.disconnect()
            control_dir.chmod(0o700)
            with self.assertRaisesRegex(machine.MachineError, "socket"):
                fixture.disconnect()
        run.assert_not_called()
        self.assertTrue(control.exists())

    def test_shared_mode_rejects_device_faults(self):
        fixture = self.fixture(recorded=True)
        with patch.object(fixture, "guest_command") as guest:
            for action in ("fault", "reclaim"):
                with self.subTest(action=action):
                    with self.assertRaisesRegex(machine.MachineError, "per-node"):
                        fixture.forward(action, ["--node", "worker"])
        guest.assert_not_called()

    def test_per_node_forwards_device_commands_without_shell(self):
        with patch.dict(os.environ, {"KIND_BLOCK_MODE": "per-node"}):
            fixture = self.fixture(recorded=True)
        with patch.object(fixture, "guest_command") as guest:
            fixture.forward("fault", ["--node", "worker;false"])
        self.assertEqual(guest.call_args.args[0], ["python3", "dev/kind_block_per_node.py", "fault",
                                                 "--node", "worker;false"])


class MachineBootstrapTests(unittest.TestCase):
    def run_bootstrap(self, missing_kind):
        temporary = tempfile.TemporaryDirectory(prefix="kind-block-bootstrap-test-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        startup = root / "bash-env"
        startup.write_text(r'''
id() { printf '0\n'; }
mkdir() { :; }
command() {
    if [[ "$1" == -v ]]; then
        [[ "$2" != kind || "$MOCK_MISSING_KIND" != true ]]
    else
        builtin command "$@"
    fi
}
uname() { printf 'x86_64\n'; }
curl() {
    case "${@: -1}" in
        *.sha256) printf 'invalid-checksum\n' > "${@: -1}" ;;
        *) printf 'untrusted-download\n' > "${@: -1}" ;;
    esac
}
install() { touch "$MOCK_INSTALL_MARKER"; }
podman() { printf '%s\n' '{"host":{"security":{"rootless":false},"serviceIsRemote":false}}'; }
modprobe() { printf '%s\n' "$*" >> "$MOCK_MODULE_LOG"; }
''' + "\npython3() { " + shlex.quote(sys.executable) + ' "$@"; }\n')
        environment = {
            "BASH_ENV": str(startup), "MOCK_MISSING_KIND": str(missing_kind).lower(),
            "MOCK_INSTALL_MARKER": str(root / "installed"), "MOCK_MODULE_LOG": str(root / "modules"),
        }
        result = subprocess.run(["/bin/bash", str(DEV / "kind-block-machine-tools.sh"), "shared"],
                                env=environment, text=True, capture_output=True, timeout=10)
        return result, root

    def test_invalid_checksum_stops_before_install(self):
        result, root = self.run_bootstrap(missing_kind=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid download checksum", result.stderr)
        self.assertFalse((root / "installed").exists())
        self.assertFalse((root / "modules").exists())

    @unittest.skipIf(Path("/dev/loop-control").is_char_device(), "The host provides loop devices.")
    def test_missing_loop_device_has_clear_error(self):
        result, root = self.run_bootstrap(missing_kind=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest kernel does not provide loop devices", result.stderr)
        self.assertEqual((root / "modules").read_text().strip(), "loop")
        self.assertFalse((root / "installed").exists())


if __name__ == "__main__":
    unittest.main()
