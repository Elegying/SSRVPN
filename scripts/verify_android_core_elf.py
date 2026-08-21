#!/usr/bin/env python3
"""Verify Android ARM64 core ABI and 16 KiB page compatibility."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1
SHT_STRTAB = 3
SHT_DYNSYM = 11
EM_AARCH64 = 183
STB_GLOBAL = 1
STT_FUNC = 2
STV_DEFAULT = 0
SHN_UNDEF = 0
MIN_LOAD_ALIGNMENT = 16 * 1024
JNI_EXPORTS = (
    b"Java_bridge_Bridge_init\0",
    b"Java_bridge_Bridge_initProtect\0",
    b"Java_bridge_Bridge_setProtectResult\0",
    b"Java_bridge_Bridge_start\0",
    b"Java_bridge_Bridge_stop\0",
    b"Java_bridge_Bridge_isRunning\0",
)
JNI_EXPORT_NAMES = frozenset(name[:-1].decode() for name in JNI_EXPORTS)


class ElfContractError(ValueError):
    pass


def _slice(data: bytes, offset: int, size: int, description: str) -> bytes:
    if offset < 0 or size < 0 or offset + size > len(data):
        raise ElfContractError(f"Android core has a truncated {description}")
    return data[offset : offset + size]


def _dynamic_exports(data: bytes) -> set[str]:
    section_offset = struct.unpack_from("<Q", data, 40)[0]
    section_entry_size = struct.unpack_from("<H", data, 58)[0]
    section_count = struct.unpack_from("<H", data, 60)[0]
    if section_entry_size < 64 or section_count == 0:
        raise ElfContractError("Android core has an invalid section header table")
    _slice(
        data,
        section_offset,
        section_entry_size * section_count,
        "section header table",
    )

    sections: list[tuple[int, int, int, int, int]] = []
    for index in range(section_count):
        offset = section_offset + index * section_entry_size
        (
            _name,
            kind,
            _flags,
            _address,
            file_offset,
            size,
            link,
            _info,
            _alignment,
            entry_size,
        ) = struct.unpack_from("<IIQQQQIIQQ", data, offset)
        sections.append((kind, file_offset, size, link, entry_size))

    exports: set[str] = set()
    found_dynamic_symbols = False
    for kind, symbol_offset, symbol_size, string_index, entry_size in sections:
        if kind != SHT_DYNSYM:
            continue
        found_dynamic_symbols = True
        if entry_size < 24 or symbol_size % entry_size != 0:
            raise ElfContractError("Android core has an invalid dynamic symbol table")
        if string_index >= len(sections):
            raise ElfContractError("Android core dynamic symbols have an invalid string table")
        string_kind, string_offset, string_size, _link, _entry_size = sections[
            string_index
        ]
        if string_kind != SHT_STRTAB:
            raise ElfContractError("Android core dynamic symbols do not link to a string table")
        strings = _slice(data, string_offset, string_size, "dynamic string table")
        symbols = _slice(data, symbol_offset, symbol_size, "dynamic symbol table")
        for offset in range(0, len(symbols), entry_size):
            name_offset, info, other, section_index = struct.unpack_from(
                "<IBBH", symbols, offset
            )
            if name_offset >= len(strings):
                raise ElfContractError("Android core dynamic symbol name is out of bounds")
            name_end = strings.find(b"\0", name_offset)
            if name_end < 0:
                raise ElfContractError("Android core dynamic symbol name is unterminated")
            try:
                name = strings[name_offset:name_end].decode("utf-8")
            except UnicodeDecodeError as error:
                raise ElfContractError(
                    "Android core dynamic symbol name is not UTF-8"
                ) from error
            if name not in JNI_EXPORT_NAMES:
                continue
            binding = info >> 4
            symbol_type = info & 0x0F
            visibility = other & 0x03
            if (
                binding == STB_GLOBAL
                and symbol_type == STT_FUNC
                and visibility == STV_DEFAULT
                and section_index != SHN_UNDEF
            ):
                exports.add(name)
    if not found_dynamic_symbols:
        raise ElfContractError("Android core has no dynamic symbol table")
    return exports


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

    exports = _dynamic_exports(data)
    missing = sorted(JNI_EXPORT_NAMES - exports)
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
