#!/usr/bin/env python3
"""Regression tests for Android core ELF contract verification."""

from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from scripts.verify_android_core_elf import ElfContractError, JNI_EXPORTS, verify


def _elf(*, bad_symbol: str | None = None, raw_names_only: bool = False) -> bytes:
    names = [name[:-1] for name in JNI_EXPORTS]
    strings = bytearray(b"\0")
    name_offsets: list[int] = []
    for name in names:
        name_offsets.append(len(strings))
        strings.extend(name + b"\0")

    symbols = bytearray(24)
    if not raw_names_only:
        for index, name_offset in enumerate(name_offsets):
            bind = 0 if bad_symbol == "local" and index == 0 else 1
            kind = 1 if bad_symbol == "object" and index == 0 else 2
            visibility = 2 if bad_symbol == "hidden" and index == 0 else 0
            section = 0 if bad_symbol == "undefined" and index == 0 else 1
            symbols.extend(
                struct.pack(
                    "<IBBHQQ",
                    name_offset,
                    (bind << 4) | kind,
                    visibility,
                    section,
                    0,
                    0,
                )
            )

    program_offset = 64
    section_offset = program_offset + 56
    section_count = 3
    data_offset = section_offset + section_count * 64
    strings_offset = data_offset
    symbols_offset = strings_offset + len(strings)
    total_size = symbols_offset + len(symbols)
    data = bytearray(total_size)

    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", data, 16, 3)
    struct.pack_into("<H", data, 18, 183)
    struct.pack_into("<I", data, 20, 1)
    struct.pack_into("<Q", data, 32, program_offset)
    struct.pack_into("<Q", data, 40, section_offset)
    struct.pack_into("<H", data, 52, 64)
    struct.pack_into("<H", data, 54, 56)
    struct.pack_into("<H", data, 56, 1)
    struct.pack_into("<H", data, 58, 64)
    struct.pack_into("<H", data, 60, section_count)

    struct.pack_into(
        "<IIQQQQQQ",
        data,
        program_offset,
        1,
        5,
        0,
        0,
        0,
        total_size,
        total_size,
        16 * 1024,
    )
    struct.pack_into(
        "<IIQQQQIIQQ",
        data,
        section_offset + 64,
        0,
        3,
        0,
        0,
        strings_offset,
        len(strings),
        0,
        0,
        1,
        0,
    )
    struct.pack_into(
        "<IIQQQQIIQQ",
        data,
        section_offset + 128,
        0,
        11,
        0,
        0,
        symbols_offset,
        len(symbols),
        1,
        1,
        8,
        24,
    )
    data[strings_offset : strings_offset + len(strings)] = strings
    data[symbols_offset : symbols_offset + len(symbols)] = symbols
    return bytes(data)


class AndroidCoreElfTests(unittest.TestCase):
    def _verify(self, payload: bytes) -> list[int]:
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / "libgojni.so"
            library.write_bytes(payload)
            return verify(library)

    def test_accepts_defined_global_default_function_exports(self) -> None:
        self.assertEqual(self._verify(_elf()), [16 * 1024])

    def test_rejects_names_that_only_exist_as_raw_strings(self) -> None:
        with self.assertRaisesRegex(ElfContractError, "missing JNI exports"):
            self._verify(_elf(raw_names_only=True))

    def test_rejects_non_runtime_exports(self) -> None:
        for defect in ("local", "object", "hidden", "undefined"):
            with self.subTest(defect=defect):
                with self.assertRaisesRegex(ElfContractError, "missing JNI exports"):
                    self._verify(_elf(bad_symbol=defect))


if __name__ == "__main__":
    unittest.main()
