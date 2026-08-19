#!/usr/bin/env python3
"""Static regression tests for the auditable Android core bridge."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "SSRVPN_Android/native/bridge/bridge.go"
BUILD_RECIPE = ROOT / "scripts/build-android-core.sh"


class AndroidCoreSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = BRIDGE.read_text(encoding="utf-8")
        cls.build_recipe = BUILD_RECIPE.read_text(encoding="utf-8")

    def test_android_build_uses_cmfa_instead_of_privileged_package_lookup(self) -> None:
        self.assertIn("-tags=with_gvisor,cmfa", self.build_recipe)

    def test_build_cleanup_handles_read_only_module_cache(self) -> None:
        self.assertIn('chmod -R u+w "$BUILD_ROOT"', self.build_recipe)
        self.assertIn('rm -rf "$BUILD_ROOT"', self.build_recipe)

    def test_required_mobile_api_is_present(self) -> None:
        for declaration in (
            "func Init(homeDir, configFile string)",
            "func InitProtect() int64",
            "func SetProtectResult(ok bool)",
            "func Start(configPath string, tunFd int64) (result string)",
            "func Stop()",
            "func IsRunning() bool",
        ):
            self.assertIn(declaration, self.source)

    def test_stop_releases_all_android_data_plane_listeners(self) -> None:
        stop = re.search(
            r"func Stop\(\) \{(?P<body>.*?)\n\}", self.source, re.DOTALL
        )
        self.assertIsNotNone(stop)
        body = stop.group("body")
        self.assertIn("listener.ReCreateMixed(0, nil)", body)
        self.assertIn("listener.ReCreateSocks(0, nil)", body)
        self.assertIn("executor.Shutdown()", body)
        self.assertLess(body.index("executor.Shutdown()"), body.index("running = false"))

    def test_tun_and_socket_protection_contract_is_preserved(self) -> None:
        for statement in (
            "cfg.General.Tun.FileDescriptor = int(tunFd)",
            'cfg.General.Tun.DNSHijack = []string{"any:53"}',
            'netip.MustParsePrefix("10.0.0.2/32")',
            "binary.LittleEndian.PutUint32(encoded[:], uint32(fd))",
            "if !<-protectResult",
        ):
            self.assertIn(statement, self.source)


if __name__ == "__main__":
    unittest.main()
