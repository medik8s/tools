#!/usr/bin/env python3
"""Release kubelet loop references to a verified fixture device after node removal."""

import errno
import fcntl
import os
from pathlib import Path
import stat
import struct
import sys


GET_STATUS64 = 0x4C05
CLEAR_FD = 0x4C01


def loop_devices():
    for entry in sorted(Path("/sys/block").glob("loop[0-9]*")):
        if not (entry / "loop/backing_file").exists():
            continue
        path = Path("/dev") / entry.name
        major, minor = map(int, (entry / "dev").read_text().strip().split(":"))
        device = path.stat()
        if not stat.S_ISBLK(device.st_mode) or device.st_rdev != os.makedev(major, minor):
            raise RuntimeError(f"Unexpected loop device: {path}")
        yield path


def status(descriptor):
    try:
        data = fcntl.ioctl(descriptor, GET_STATUS64, bytes(232))
    except OSError as error:
        if error.errno == errno.ENXIO:
            return None
        raise
    return struct.unpack_from("=QQQ", data)


def release_references(device):
    source = Path(device).stat()
    if not stat.S_ISBLK(source.st_mode):
        raise RuntimeError(f"The source is not a block device: {device}")
    for path in loop_devices():
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            original = status(descriptor)
            if original is None or original[2] != source.st_rdev:
                continue
            if status(descriptor) != original:
                raise RuntimeError(f"The loop reference changed: {path}")
            fcntl.ioctl(descriptor, CLEAR_FD)
        finally:
            os.close(descriptor)
    for path in loop_devices():
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            remaining = status(descriptor)
            if remaining is not None and remaining[2] == source.st_rdev:
                raise RuntimeError(f"The loop reference remains busy: {path}")
        finally:
            os.close(descriptor)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise RuntimeError("Specify one verified fixture device.")
        release_references(sys.argv[1])
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Block reference cleanup: {error}", file=sys.stderr)
        sys.exit(1)
