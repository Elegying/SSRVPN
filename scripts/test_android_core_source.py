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

    def test_relative_build_output_survives_temporary_source_cleanup(self) -> None:
        normalize = self.build_recipe.index('case "$OUTPUT" in')
        change_directory = self.build_recipe.index('cd "$SOURCE_DIR"')
        self.assertLess(normalize, change_directory)
        self.assertIn('*) OUTPUT="$ROOT/$OUTPUT" ;;', self.build_recipe)

    def test_repeat_builds_reuse_content_addressed_go_caches(self) -> None:
        self.assertIn('GO_MODULE_CACHE="${GOMODCACHE:-$("$GO_BIN" env GOMODCACHE)}"', self.build_recipe)
        self.assertIn('GO_BUILD_CACHE="${GOCACHE:-$("$GO_BIN" env GOCACHE)}"', self.build_recipe)
        self.assertIn('export GOMODCACHE="$GO_MODULE_CACHE"', self.build_recipe)
        self.assertIn('export GOCACHE="$GO_BUILD_CACHE"', self.build_recipe)
        self.assertNotIn('GOCACHE_DIR="$BUILD_ROOT/', self.build_recipe)

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
            "session.wait(protectResultTimeout)",
        ):
            self.assertIn(statement, self.source)

    def test_socket_protection_serializes_each_request_with_its_result(self) -> None:
        hook_start = self.source.index("func protectSocket(")
        hook_end = self.source.index(
            "\n}\n\n// releaseProtectLocked", hook_start
        )
        body = self.source[hook_start:hook_end]
        for statement in (
            "session.requestMu.Lock()",
            "defer session.requestMu.Unlock()",
            "connection.Control",
            "session.writer.Write",
            "session.wait(protectResultTimeout)",
        ):
            self.assertIn(statement, body)
        self.assertLess(
            body.index("session.requestMu.Lock()"), body.index("connection.Control")
        )
        self.assertLess(
            body.index("session.writer.Write"),
            body.index("session.wait(protectResultTimeout)"),
        )
        self.assertIn("retireProtectSession(session)", body)

        reporter = re.search(
            r"func SetProtectResult\(ok bool\) \{(?P<body>.*?)\n\}",
            self.source,
            re.DOTALL,
        )
        self.assertIsNotNone(reporter)
        self.assertNotIn("protectRequestMu", reporter.group("body"))
        self.assertIn("currentProtectSession()", reporter.group("body"))
        self.assertIn("session.report(ok)", reporter.group("body"))

    def test_stop_cancels_protect_waiters_before_core_shutdown(self) -> None:
        stop = re.search(
            r"func Stop\(\) \{(?P<body>.*?)\n\}", self.source, re.DOTALL
        )
        self.assertIsNotNone(stop)
        body = stop.group("body")
        self.assertIn("protectStopRequests.Add(1)", body)
        self.assertIn("replaceProtectSession(nil)", body)
        self.assertLess(body.index("replaceProtectSession(nil)"), body.index("coreMu.Lock()"))
        self.assertIn("releaseProtectLocked()", body)
        self.assertLess(body.index("releaseProtectLocked()"), body.index("executor.Shutdown()"))

    def test_init_protect_publishes_a_cancellable_session_before_start(self) -> None:
        init_protect = re.search(
            r"func InitProtect\(\) int64 \{(?P<body>.*?)\n\}",
            self.source,
            re.DOTALL,
        )
        self.assertIsNotNone(init_protect)
        body = init_protect.group("body")
        self.assertIn("installProtectSession(session)", body)
        self.assertIn("protectStopRequests", self.source)

        start = re.search(
            r"func Start\(configPath string, tunFd int64\) \(result string\) "
            r"\{(?P<body>.*?)\n\}",
            self.source,
            re.DOTALL,
        )
        self.assertIsNotNone(start)
        self.assertNotIn("installProtectSession(", start.group("body"))
        self.assertIn("if !protectReadyForStart(tunFd)", start.group("body"))

    def test_init_protect_transfers_a_close_on_exec_reader_duplicate(self) -> None:
        init_protect = re.search(
            r"func InitProtect\(\) int64 \{(?P<body>.*?)\n\}",
            self.source,
            re.DOTALL,
        )
        self.assertIsNotNone(init_protect)
        body = init_protect.group("body")
        for statement in (
            "transferFd, err := syscall.Dup(readFd)",
            "syscall.CloseOnExec(transferFd)",
            "return int64(transferFd)",
        ):
            self.assertIn(statement, body)
        self.assertNotIn("return int64(readPipe.Fd())", body)
        self.assertLess(body.index("coreMu.Lock()"), body.index("syscall.Dup(readFd)"))
        self.assertLess(body.index("syscall.Dup(readFd)"), body.rindex("coreMu.Unlock()"))

    def test_socket_hook_uses_one_stable_dispatcher_for_process_lifetime(self) -> None:
        assignments = re.findall(
            r"dialer\.DefaultSocketHook\s*=\s*([^\n]+)", self.source
        )
        self.assertEqual(assignments, ["protectSocket"])
        self.assertNotIn("dialer.DefaultSocketHook = nil", self.source)

    def test_build_runs_concurrent_protect_session_tests(self) -> None:
        self.assertIn('bridge/bridge_test.go', self.build_recipe)
        self.assertIn(
            '"$GO_BIN" test -tags=with_gvisor,cmfa ./bridge', self.build_recipe
        )


if __name__ == "__main__":
    unittest.main()
