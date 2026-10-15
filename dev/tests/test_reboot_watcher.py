"""Exercise the SBR and SNR watcher with fake Kubernetes and container commands."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


WATCHER = Path(__file__).resolve().parents[1] / "kind-reboot-watcher.sh"

MOCK = r'''
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["MOCK_ROOT"])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
rounds = json.loads(os.environ["MOCK_ROUNDS"])
lifecycle = os.environ.get("MOCK_LIFECYCLE") == "true"

def count(name):
    path = root / name
    return int(path.read_text()) if path.exists() else 0

def save(name, value):
    (root / name).write_text(str(value))

restarts = count("restarts")
if tool == "kind":
    if args == ["get", "clusters"]:
        if lifecycle:
            if restarts == 0 and count("polls-0") > 0:
                save("early-ready", 1)
            scans = count("scans")
            save("scans", scans + 1)
            if scans < 30:
                print("watcher-test")
        elif restarts < len(rounds):
            print("watcher-test")
    elif args[:2] == ["get", "nodes"]:
        print("watcher-test-worker")
elif tool == "kubectl":
    if args[:2] == ["get", "node"]:
        if lifecycle:
            if restarts == 0:
                ready = count("polls-0") > 0
                if ready:
                    save("early-ready", 1)
            else:
                polls = count("recovery-polls")
                save("recovery-polls", polls + 1)
                ready = polls not in (1, 2)
            heartbeat = "2000-01-01T00:00:00Z" if count("recovery-polls") < 4 else "2099-01-01T00:00:00Z"
        else:
            ready = restarts > count("ready")
            if ready:
                save("ready", restarts)
            heartbeat = "2099-01-01T00:00:00Z"
        status = "True" if ready else "False"
        print(status + ":" + heartbeat if "lastHeartbeatTime" in " ".join(args) else status)
    elif args[:2] in (["get", "storagebasedremediation"], ["get", "selfnoderemediation"]):
        with (root / "resources").open("a") as out:
            out.write(args[1] + "\n")
        key = f"polls-{restarts}"
        polls = count(key)
        save(key, polls + 1)
        states = rounds[min(restarts, len(rounds) - 1)]
        if lifecycle and restarts == 0 and polls == 0:
            time.sleep(1)
        print(states[min(polls, len(states) - 1)])
elif tool == "docker":
    if args[0] == "restart":
        save("restarts", restarts + 1)
    elif args[0] == "exec":
        with (root / "watchdogs").open("a") as out:
            out.write(args[1] + "\n")
elif tool == "sleep":
    time.sleep(0.01)
'''


class SBRRebootWatcher(unittest.TestCase):
    def run_watcher(self, rounds, once=True, mode="sbr", lifecycle=False):
        with tempfile.TemporaryDirectory(prefix="reboot-watcher-test-") as directory:
            root = Path(directory)
            commands = root / "bin"
            commands.mkdir()
            for name in ("kind", "kubectl", "docker", "sleep"):
                command = commands / name
                command.write_text(f"#!{sys.executable}\n" + MOCK)
                command.chmod(0o755)
            env = dict(os.environ) | {
                "PATH": f"{commands}:{os.environ['PATH']}",
                "MOCK_ROOT": directory, "MOCK_ROUNDS": json.dumps(rounds),
                "MOCK_LIFECYCLE": str(lifecycle).lower(),
                "KUBECTL": "kubectl", "CONTAINER_TOOL": "docker",
                "TMPDIR": directory,
                "MEDIK8S_REBOOT_WATCHER_MODE": "snr",
            }
            args = ["bash", str(WATCHER), "--name", "watcher-test", "--delay", "15"]
            if mode is not None:
                args.extend(["--mode", mode])
            if once:
                args.append("--once")
            result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(int((root / "restarts").read_text()), len(rounds))
            if mode == "sbr":
                self.assertEqual((root / "watchdogs").read_text().splitlines(),
                                 ["watcher-test-worker"] * len(rounds))
            else:
                self.assertFalse((root / "watchdogs").exists())
                self.assertEqual(set((root / "resources").read_text().splitlines()),
                                 {"selfnoderemediation"})
            polls = [int((root / f"polls-{i}").read_text()) for i in range(len(rounds))]
            self.assertEqual(list(root.glob("sbr-reboot-watcher.*")), [])
            if lifecycle:
                self.assertTrue((root / "early-ready").exists())
                self.assertGreaterEqual(int((root / "recovery-polls").read_text()), 4)
            return result.stdout, polls

    def test_ready_before_handler_finishes_does_not_launch_second_restart(self):
        output, _ = self.run_watcher([["active:False", "active:True"]],
                                     once=False, lifecycle=True)
        self.assertEqual(output.count("NotReady detected"), 1)
        self.assertNotIn("timeout waiting", output)
        self.assertLess(output.index("container restarted"), output.index("reboot complete"))

    def test_existing_completed_cr_restarts_without_timeout(self):
        output, polls = self.run_watcher([["active:True"]])
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [1])

    def test_existing_pending_cr_waits_for_fencing(self):
        output, polls = self.run_watcher([["active:False", "active:False", "active:True"]])
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [3])

    def test_cr_created_after_not_ready(self):
        output, polls = self.run_watcher([[":", "new:False", "new:True"]])
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [3])

    def test_incomplete_or_missing_cr_uses_timeout(self):
        for state in ("active:False", ":", ""):
            with self.subTest(state=state):
                output, polls = self.run_watcher([[state]])
                self.assertIn("timeout waiting for FencingSucceeded", output)
                self.assertEqual(polls, [3])

    def test_handled_cr_ignored_but_next_uid_accepted(self):
        output, polls = self.run_watcher(
            [["first:True"], ["first:True"], ["second:True"]], once=False)
        self.assertEqual(output.count("timeout waiting for FencingSucceeded"), 1)
        self.assertEqual(polls, [1, 3, 1])

    def test_timeout_also_records_handled_uid(self):
        output, polls = self.run_watcher([["first:False"], ["first:True"]], once=False)
        self.assertEqual(output.count("timeout waiting for FencingSucceeded"), 2)
        self.assertEqual(polls, [3, 3])


    def test_snr_new_cr(self):
        output, polls = self.run_watcher([["", "new"]], mode="snr")
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [2])

    def test_snr_replacement_cr(self):
        output, polls = self.run_watcher([["old", "old", "new"]], mode="snr")
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [3])

    def test_snr_existing_or_missing_cr_times_out(self):
        for uid in ("old", ""):
            with self.subTest(uid=uid):
                output, polls = self.run_watcher([[uid]], mode="snr")
                self.assertIn("timeout waiting for CR", output)
                self.assertEqual(polls, [4])

    def test_snr_is_default_mode(self):
        output, polls = self.run_watcher([["", "new"]], mode=None)
        self.assertIn("[reboot-watcher/snr]", output)
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [2])

    def test_snr_multiple_restarts(self):
        output, polls = self.run_watcher([["", "first"], ["first", "second"]],
                                         once=False, mode="snr")
        self.assertNotIn("timeout waiting", output)
        self.assertEqual(polls, [2, 2])


if __name__ == "__main__":
    unittest.main()
