"""Check reference cleanup without kernel devices or root access."""

import errno
import importlib.util
import os
from pathlib import Path
import stat
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import call, patch


SPEC = importlib.util.spec_from_file_location(
    "kind_block_references", Path(__file__).resolve().parents[1] / "kind_block_references.py")
references = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(references)


class ReferenceCleanupTests(unittest.TestCase):
    def setUp(self):
        self.source = os.makedev(253, 8)
        self.real_stat = Path.stat
        self.source_stat = patch.object(
            references.Path, "stat", return_value=SimpleNamespace(
                st_mode=stat.S_IFBLK | 0o600, st_rdev=self.source))
        self.source_stat.start()
        self.addCleanup(self.source_stat.stop)

    def test_status_reads_kernel_backing_device_identity(self):
        identity = (os.makedev(0, 7), 123, self.source)
        with patch.object(references.fcntl, "ioctl", return_value=struct.pack("=QQQ", *identity) + bytes(208)):
            self.assertEqual(references.status(10), identity)

    def test_unattached_loop_is_absent_but_other_kernel_errors_propagate(self):
        with patch.object(references.fcntl, "ioctl", side_effect=OSError(errno.ENXIO, "unattached")):
            self.assertIsNone(references.status(10))
        with patch.object(references.fcntl, "ioctl", side_effect=OSError(errno.EIO, "read failed")):
            with self.assertRaises(OSError):
                references.status(10)

    def test_regular_source_cannot_trigger_device_cleanup(self):
        with patch.object(references.Path, "stat", return_value=SimpleNamespace(st_mode=stat.S_IFREG)):
            with patch.object(references, "loop_devices") as devices:
                with self.assertRaisesRegex(RuntimeError, "not a block device"):
                    references.release_references("/tmp/source")
        devices.assert_not_called()

    def test_loop_discovery_rejects_replaced_device_nodes(self):
        self.source_stat.stop()
        with tempfile.TemporaryDirectory(prefix="kind-block-reference-test-", dir="/tmp") as directory:
            root = Path(directory)
            entry = root / "sys" / "loop7"
            (entry / "loop").mkdir(parents=True)
            (entry / "loop" / "backing_file").touch()
            (entry / "dev").write_text("7:7\n")
            (root / "dev").mkdir()

            def path(value):
                return root / ("sys" if value == "/sys/block" else "dev")

            for mode, device in [(stat.S_IFREG, os.makedev(7, 7)),
                                 (stat.S_IFBLK, os.makedev(7, 8))]:
                with self.subTest(mode=mode, device=device):
                    def device_stat(path, *args, **kwargs):
                        if path == root / "dev" / "loop7":
                            return SimpleNamespace(st_mode=mode, st_rdev=device)
                        return self.real_stat(path, *args, **kwargs)

                    with patch.object(references, "Path", side_effect=path):
                        with patch.object(Path, "stat", autospec=True, side_effect=device_stat):
                            with patch.object(references.os, "mknod"):
                                with self.assertRaisesRegex(RuntimeError, "Unexpected loop device"):
                                    list(references.loop_devices())

    def test_loop_discovery_creates_missing_device_nodes(self):
        self.source_stat.stop()
        with tempfile.TemporaryDirectory(prefix="kind-block-reference-test-", dir="/tmp") as directory:
            root = Path(directory)
            entry = root / "sys" / "loop7"
            (entry / "loop").mkdir(parents=True)
            (entry / "loop" / "backing_file").touch()
            (entry / "dev").write_text("7:7\n")
            (root / "dev").mkdir()

            def path(value):
                return root / ("sys" if value == "/sys/block" else "dev")

            def device_stat(p, *args, **kwargs):
                if p == root / "dev" / "loop7":
                    if not mknod.called:
                        raise FileNotFoundError(errno.ENOENT, "No such file or directory", str(p))
                    return SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(7, 7))
                return self.real_stat(p, *args, **kwargs)

            with patch.object(references, "Path", side_effect=path):
                with patch.object(Path, "stat", autospec=True, side_effect=device_stat):
                    with patch.object(references.os, "mknod") as mknod:
                        self.assertEqual(list(references.loop_devices()), [root / "dev" / "loop7"])
            mknod.assert_called_once_with(root / "dev" / "loop7",
                                           0o600 | stat.S_IFBLK, os.makedev(7, 7))

    def test_only_exact_backing_device_references_are_released(self):
        paths = [Path("/dev/loop7"), Path("/dev/loop8"), Path("/dev/loop9")]
        matching = (7, 100, self.source)
        unrelated = (7, 101, os.makedev(253, 9))
        events = []
        identities = {7: matching, 8: unrelated, 9: None}

        def kernel(descriptor, operation):
            self.assertEqual(operation, references.CLEAR_FD)
            self.assertEqual(descriptor, 7)
            events.append(("clear", descriptor))
            identities[descriptor] = None

        def close(descriptor):
            events.append(("close", descriptor))

        with patch.object(references, "loop_devices", side_effect=[iter(paths), iter(paths)]):
            with patch.object(references.os, "open", side_effect=[7, 8, 9, 7, 8, 9]):
                with patch.object(references.os, "close", side_effect=close):
                    with patch.object(references, "status", side_effect=lambda fd: identities[fd]):
                        with patch.object(references.fcntl, "ioctl", side_effect=kernel) as ioctl:
                            references.release_references("/dev/mapper/owned")
        ioctl.assert_called_once_with(7, references.CLEAR_FD)
        self.assertEqual(events, [("clear", 7), ("close", 7), ("close", 8),
                                  ("close", 9), ("close", 7), ("close", 8), ("close", 9)])

    def test_changed_reference_is_preserved_and_descriptor_is_closed(self):
        original = (7, 100, self.source)
        changed = (7, 101, self.source)
        with patch.object(references, "loop_devices", return_value=iter([Path("/dev/loop7")])):
            with patch.object(references.os, "open", return_value=7):
                with patch.object(references.os, "close") as close:
                    with patch.object(references, "status", side_effect=[original, changed]):
                        with patch.object(references.fcntl, "ioctl") as ioctl:
                            with self.assertRaisesRegex(RuntimeError, "reference changed"):
                                references.release_references("/dev/mapper/owned")
        ioctl.assert_not_called()
        close.assert_called_once_with(7)

    def test_busy_reference_cannot_report_success_after_autoclear(self):
        identity = (7, 100, self.source)
        with patch.object(references, "loop_devices", side_effect=[iter([Path("/dev/loop7")]),
                                                                  iter([Path("/dev/loop7")])]):
            with patch.object(references.os, "open", return_value=7):
                with patch.object(references.os, "close") as close:
                    with patch.object(references, "status", return_value=identity):
                        with patch.object(references.fcntl, "ioctl"):
                            with self.assertRaisesRegex(RuntimeError, "remains busy"):
                                references.release_references("/dev/mapper/owned")
        self.assertEqual(close.call_args_list, [call(7), call(7)])

    def test_kernel_cleanup_error_closes_descriptor(self):
        identity = (7, 100, self.source)
        with patch.object(references, "loop_devices", return_value=iter([Path("/dev/loop7")])):
            with patch.object(references.os, "open", return_value=7):
                with patch.object(references.os, "close") as close:
                    with patch.object(references, "status", return_value=identity):
                        with patch.object(references.fcntl, "ioctl", side_effect=OSError(errno.EBUSY, "busy")):
                            with self.assertRaises(OSError):
                                references.release_references("/dev/mapper/owned")
        close.assert_called_once_with(7)


if __name__ == "__main__":
    unittest.main()
