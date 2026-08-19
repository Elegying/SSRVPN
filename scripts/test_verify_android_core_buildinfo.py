from __future__ import annotations

import unittest

from scripts.verify_android_core_buildinfo import (
    BUILD_INFO_END,
    BUILD_INFO_START,
    BuildInfoError,
    parse_build_info,
)


def _uvarint(value: int) -> bytes:
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def _binary(module_lines: list[str], *, flags: int = 2) -> bytes:
    version = b"go1.25.11"
    module = (
        BUILD_INFO_START
        + "\n".join(module_lines).encode()
        + BUILD_INFO_END
    )
    header = b"\xff Go buildinf:" + bytes((8, flags)) + bytes(16)
    return (
        b"prefix"
        + header
        + _uvarint(len(version))
        + version
        + _uvarint(len(module))
        + module
    )


class AndroidCoreBuildInfoTest(unittest.TestCase):
    def test_parses_local_mihomo_replacement_and_target(self) -> None:
        info = parse_build_info(
            _binary(
                [
                    "path\tgobind/gobind",
                    "mod\tgobind\t(devel)\t",
                    "dep\tgithub.com/metacubex/mihomo\tv0.0.0-00010101000000-000000000000",
                    "=>\tC:\\Users\\builder\\mihomo\t(devel)\t",
                    "build\t-buildmode=c-shared",
                    "build\t-tags=with_gvisor,cmfa",
                    "build\tGOARCH=arm64",
                    "build\tGOOS=android",
                ]
            )
        )

        self.assertEqual(info.go_version, "go1.25.11")
        self.assertEqual(
            info.dependencies["github.com/metacubex/mihomo"],
            "v0.0.0-00010101000000-000000000000",
        )
        self.assertIn("github.com/metacubex/mihomo", info.local_replacements)
        self.assertEqual(info.settings["GOOS"], "android")
        self.assertEqual(info.settings["GOARCH"], "arm64")
        self.assertEqual(info.settings["-buildmode"], "c-shared")
        self.assertEqual(info.settings["-tags"], "with_gvisor,cmfa")

    def test_rejects_pointer_encoded_legacy_build_info(self) -> None:
        with self.assertRaisesRegex(BuildInfoError, "inline Go build info"):
            parse_build_info(_binary([], flags=0))

    def test_rejects_truncated_module_payload(self) -> None:
        payload = _binary(["path\tgobind/gobind"])
        with self.assertRaisesRegex(BuildInfoError, "module framing"):
            parse_build_info(payload[:-16])


if __name__ == "__main__":
    unittest.main()
