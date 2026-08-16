#!/usr/bin/env python3
"""Apply the reviewed ARM64 Bridge.stop shutdown hook to the pinned Go core."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import tempfile
from pathlib import Path


UPSTREAM_SHA256 = "65f8921583a778e218a5e735752e33f9a1ba53c0b5b11c2a0f80c8f6dbac08a1"
PATCHED_SHA256 = "ec0b7fb285c4052c0050bc0fb27599dee1459677267881febbd1ec1cb88d5c46"
PATCH_OFFSET = 0x19D63AC
ORIGINAL_INSTRUCTIONS = bytes.fromhex(
    "605ffff000940991e10f40b2e2031faae3031faae40303aaefc8c397"
)
PATCHED_INSTRUCTIONS = bytes.fromhex(
    "e0031faa1c91fd97e0031faa4288fd978539ff971f2003d51f2003d5"
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate_patched(data: bytes) -> None:
    actual = digest(data)
    if actual != PATCHED_SHA256:
        raise SystemExit(
            f"patched Android core SHA256 mismatch: expected {PATCHED_SHA256}, got {actual}"
        )
    end = PATCH_OFFSET + len(PATCHED_INSTRUCTIONS)
    if data[PATCH_OFFSET:end] != PATCHED_INSTRUCTIONS:
        raise SystemExit("Android core data-plane shutdown hook is missing")


def patch(path: Path) -> None:
    data = path.read_bytes()
    if digest(data) == PATCHED_SHA256:
        validate_patched(data)
        print(f"ok Android core shutdown hook: {path}")
        return
    actual = digest(data)
    if actual != UPSTREAM_SHA256:
        raise SystemExit(
            f"unsupported Android core SHA256: expected {UPSTREAM_SHA256}, got {actual}"
        )
    end = PATCH_OFFSET + len(ORIGINAL_INSTRUCTIONS)
    if data[PATCH_OFFSET:end] != ORIGINAL_INSTRUCTIONS:
        raise SystemExit("pinned Android core no longer has the reviewed Bridge.stop call site")

    patched = bytearray(data)
    patched[PATCH_OFFSET:end] = PATCHED_INSTRUCTIONS
    validate_patched(patched)

    mode = stat.S_IMODE(path.stat().st_mode)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temporary.write(patched)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    temporary_path.chmod(mode)
    os.replace(temporary_path, path)
    print(f"patched Android core shutdown hook: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if args.check:
        validate_patched(args.library.read_bytes())
        print(f"ok Android core shutdown hook: {args.library}")
    else:
        patch(args.library)


if __name__ == "__main__":
    main()
