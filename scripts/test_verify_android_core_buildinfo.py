from __future__ import annotations

import unittest
import hashlib
import json
from pathlib import Path
import tempfile

from scripts.verify_android_core_buildinfo import (
    BUILD_INFO_END,
    BUILD_INFO_START,
    BuildInfoError,
    parse_build_info,
    verify,
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
    def verify_fixture(self, *, embedded_version=None, recorded_version=None, link_flags=None):
        root = Path(__file__).resolve().parents[1]
        fields = dict(line.split(': ', 1) for line in
                      (root / 'SSRVPN_Android/assets/libgojni-source.txt').read_text().splitlines()
                      if ': ' in line)
        pinned = json.loads((root / 'native/proxy_traffic/sources.json').read_text())['android']
        expected = pinned['version'] + '-ssrvpn.1'
        fields['Core version'] = expected if recorded_version is None else recorded_version
        fields['Link flags'] = (f'-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version={expected}'
                                if link_flags is None else link_flags)
        bridge = b'synthetic bridge fixture'
        fields['Bridge SHA256'] = hashlib.sha256(bridge).hexdigest()
        data = _binary([
            f"dep\t{fields['Go module']}\t{fields['Go module version']}",
            '=>\t/tmp/fixture/mihomo\t(devel)\t',
            f"dep\tgolang.org/x/mobile\t{fields['Go mobile version']}",
            'build\t-buildmode=c-shared', 'build\t-tags=with_gvisor,cmfa',
            'build\tGOARCH=arm64', 'build\tGOOS=android', 'build\t-trimpath=true',
        ]) + b'\0' + (expected if embedded_version is None else embedded_version).encode() + b'\0'
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            record = fixture / 'SSRVPN_Android/assets/libgojni-source.txt'
            record.parent.mkdir(parents=True)
            record.write_text(''.join(f'{key}: {value}\n' for key, value in fields.items()))
            bridge_file = fixture / fields['Bridge source']
            bridge_file.parent.mkdir(parents=True)
            bridge_file.write_bytes(bridge)
            sources = fixture / 'native/proxy_traffic/sources.json'
            sources.parent.mkdir(parents=True)
            sources.write_text(json.dumps({'android': pinned}))
            binary = fixture / 'libgojni.so'
            binary.write_bytes(data)
            return verify(binary, record)

    def test_accepts_pinned_custom_version_in_binary_and_recipe(self):
        self.verify_fixture()

    def test_rejects_binary_without_custom_version_despite_correct_metadata(self):
        with self.assertRaisesRegex(BuildInfoError, 'embedded core version'):
            self.verify_fixture(embedded_version='1.10.0')

    def test_rejects_version_record_that_disagrees_with_pinned_source(self):
        with self.assertRaisesRegex(BuildInfoError, 'Core version'):
            self.verify_fixture(recorded_version='unrelated-ssrvpn.1')

    def test_rejects_recipe_without_version_injection(self):
        with self.assertRaisesRegex(BuildInfoError, 'Link flags'):
            self.verify_fixture(link_flags='-s -w -buildid=')

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
