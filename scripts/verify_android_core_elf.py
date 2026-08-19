#!/usr/bin/env python3
"""Verify Android ARM64 core ABI and 16 KiB page compatibility."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1
EM_AARCH64 = 183
MIN_LOAD_ALIGNMENT = 16 * 1024
JNI_EXPORTS = (
    b"Java_bridge_Bridge_init\0",
    b"Java_bridge_Bridge_initProtect\0",
    b"Java_bridge_Bridge_setProtectResult\0",
    b"Java_bridge_Bridge_start\0",
    b"Java_bridge_Bridge_stop\0",
    b"Java_bridge_Bridge_isRunning\0",
)


class ElfContractError(ValueError):
    pass


def verify(path: Path) -> list[int]:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != ELF_MAGIC:
        raise ElfContractError("Android core is not an ELF binary")
    if data[4] != 2 or data[5] != 1:
        raise ElfContractError("Android core must be little-endian ELF64")

    machine = struct.unpack_from("<H", data, 18)[0]
    if machine != EM_AARCH64:
        raise ElfContractError(f"Android core machine must be AArch64, got {machine}")

    program_offset = struct.unpack_from("<Q", data, 32)[0]
    program_entry_size = struct.unpack_from("<H", data, 54)[0]
    program_count = struct.unpack_from("<H", data, 56)[0]
    if program_entry_size < 56:
        raise ElfContractError("Android core has an invalid program header size")

    alignments: list[int] = []
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        if offset + 56 > len(data):
            raise ElfContractError("Android core has a truncated program header table")
        kind, _flags, file_offset, virtual_address, _physical_address, _file_size, _memory_size, alignment = struct.unpack_from(
            "<IIQQQQQQ", data, offset
        )
        if kind != PT_LOAD:
            continue
        alignments.append(alignment)
        if alignment < MIN_LOAD_ALIGNMENT:
            raise ElfContractError(
                f"Android core LOAD segment {index} uses {alignment}-byte alignment; 16384 is required"
            )
        if file_offset % alignment != virtual_address % alignment:
            raise ElfContractError(
                f"Android core LOAD segment {index} has incongruent file and virtual offsets"
            )
    if not alignments:
        raise ElfContractError("Android core has no LOAD segments")

    missing = [name[:-1].decode() for name in JNI_EXPORTS if name not in data]
    if missing:
        raise ElfContractError(f"Android core is missing JNI exports: {', '.join(missing)}")
    return alignments


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    try:
        alignments = verify(args.library)
    except ElfContractError as error:
        raise SystemExit(f"Android core ELF check failed: {error}") from error
    print(
        "ok Android core ELF: AArch64, JNI ABI present, LOAD alignments "
        + ", ".join(str(value) for value in alignments)
    )


if __name__ == "__main__":
    main()
