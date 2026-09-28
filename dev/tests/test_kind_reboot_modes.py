"""Keep the existing SNR/SBR reboot signals separate from MDR deletion."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


DEV = Path(__file__).resolve().parents[1]
MOCK = r'''#!/bin/bash
set -eu
printf '%s %s\n' "${0##*/}" "$*" >> "$MOCK_ROOT/calls"
case "${0##*/}" in
  kind)
    case "$*" in
      'get clusters') echo test ;;
      'get nodes --name test') echo test-worker ;;
      *) exit 99 ;;
    esac ;;
  kubectl)
    case "$*" in
      'get node '*) echo False ;;
      'get selfnoderemediation '*|'get storagebasedremediation '*)
        count=$(cat "$MOCK_ROOT/count")
        echo $((count + 1)) > "$MOCK_ROOT/count"
        if [[ "$MOCK_SIGNAL" == snr ]]; then
          if [[ "$count" == 0 ]]; then echo old; else echo new; fi
        else
          case "$count" in
            0|1) echo old:True ;;
            2) echo new:False ;;
            *) echo new:True ;;
          esac
        fi ;;
      *) exit 99 ;;
    esac ;;
  docker) [[ "$1" == restart || "$1" == exec ]] ;;
  sleep) : ;;
  *) exit 99 ;;
esac
'''


class ExistingRebootModes(unittest.TestCase):
    def test_snr_and_sbr_keep_their_existing_signal_and_restart(self):
        for mode, expected_queries in [("snr", 2), ("sbr", 4)]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "count").write_text("0")
                for tool in ("kind", "kubectl", "docker", "sleep"):
                    path = root / tool
                    path.write_text(MOCK)
                    path.chmod(0o755)
                env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                           MOCK_ROOT=directory, MOCK_SIGNAL=mode,
                           KUBECTL=str(root / "kubectl"), CONTAINER_TOOL=str(root / "docker"))
                result = subprocess.run(["bash", str(DEV / "kind-reboot-watcher.sh"),
                                         "--mode", mode, "--once", "--name", "test", "--delay", "30"],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(int((root / "count").read_text()), expected_queries)
                calls = (root / "calls").read_text()
                self.assertEqual(calls.count("docker restart test-worker"), 1)
                self.assertNotIn("docker rm", calls)
                self.assertNotIn("forcing restart", result.stdout)


if __name__ == "__main__":
    unittest.main()
