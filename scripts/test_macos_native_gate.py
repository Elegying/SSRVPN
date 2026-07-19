from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MacosNativeGateTest(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_native_runner_executes_runner_tests_only_on_macos(self) -> None:
        runner = self.read("scripts/test-macos-native.sh")

        self.assertIn('[[ "$(uname -s)" != "Darwin" ]]', runner)
        self.assertIn("flutter build macos --debug --config-only --no-pub", runner)
        self.assertIn("xcodebuild test", runner)
        self.assertIn("-only-testing:RunnerTests", runner)
        self.assertIn("-parallel-testing-enabled NO", runner)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", runner)

    def test_native_runner_is_wired_into_all_macos_quality_gates(self) -> None:
        verify_all = self.read("scripts/verify-all.sh")
        ci = self.read(".github/workflows/ci.yml")
        release = self.read(".github/workflows/release.yml")
        testing = self.read("docs/TESTING.md")

        self.assertIn('run_step "macOS native unit tests" scripts/test-macos-native.sh', verify_all)
        self.assertRegex(
            ci,
            r"(?s)name: macOS native unit tests.+?matrix\.directory == 'SSRVPN_MacOS'.+?"
            r"bash scripts/test-macos-native\.sh",
        )
        self.assertRegex(
            release,
            r"(?s)name: macOS native unit tests.+?bash scripts/test-macos-native\.sh",
        )
        self.assertIn("scripts/test-macos-native.sh", testing)

    def test_signal_ownership_gate_has_no_fail_open_default(self) -> None:
        app_delegate = self.read("SSRVPN_MacOS/macos/Runner/AppDelegate.swift")
        signature = re.search(
            r"func terminateConfirmedCoreProcess\((.*?)\n  \) -> Bool",
            app_delegate,
            flags=re.DOTALL,
        )

        self.assertIsNotNone(signature)
        parameters = signature.group(1)
        self.assertIn("canSignalProcess: (Int32, Int32) -> Bool,", parameters)
        self.assertNotRegex(
            parameters,
            r"canSignalProcess:\s*\(Int32, Int32\) -> Bool\s*=",
        )

    def test_pid_generation_is_persisted_and_compared_end_to_end(self) -> None:
        app_delegate = self.read("SSRVPN_MacOS/macos/Runner/AppDelegate.swift")
        main_window = self.read(
            "SSRVPN_MacOS/macos/Runner/MainFlutterWindow.swift"
        )
        lifecycle = self.read(
            "SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart"
        )

        for token in (
            "func acquireInstanceLease(at url: URL? = nil) -> Bool",
            "flock(descriptor, LOCK_EX | LOCK_NB)",
            "performTerminationCleanupIfLeaseOwner",
            "private let coreProcessOperationQueue = DispatchQueue(",
            "func enqueueCoreProcessOperation(_ operation: @escaping () -> Void)",
            "func performCoreProcessOperationAndWait(_ operation: () -> Void)",
            "override func applicationShouldTerminate(",
            "return .terminateLater",
            "func beginProxyLifecycleTransaction() -> String",
            "func endProxyLifecycleTransaction(token: String) -> Bool",
            "struct CorePidRecord: Equatable",
            "struct CoreProcessGeneration: Equatable",
            "struct CoreLaunchResult: Equatable",
            "struct CoreProcessStatus: Equatable",
            "private final class NativeOwnedCoreProcess",
            "private final class CoreOutputCapture",
            "func launchOwnedCore(",
            "identityPollCount: Int = 51",
            "containLaunchedCoreProcess(process)",
            "containTrackedCoreWithoutRecord(in: directory)",
            '"v2 \\(pid) \\(startSeconds) \\(startMicroseconds)\\n"',
            "O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK",
            "fileInfo.st_size <= 128",
            "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW",
            "writePidRecordAtomically",
            "generationBefore == generationAfter",
            "text == expectedContents",
            "Darwin.lstat",
            "func readProxyStateData(at url: URL) -> Data?",
            "func proxyStatePathEntryExists(at url: URL) -> Bool",
            "fileInfo.st_mode & (S_IWGRP | S_IWOTH) == 0",
            "fileInfo.st_size <= 1_048_576",
            "Proxy restore state has no ownership proof; preserving it",
            "validatedProxyServices(in: root)",
        ):
            self.assertIn(token, app_delegate)
        for method in (
            "launchOwnedCore",
            "ownedCoreStatus",
            "terminateOwnedCore",
            "terminateOwnedCoreRecord",
            "removeOwnedCorePidRecord",
        ):
            self.assertIn(f'case "{method}"', main_window)
            self.assertIn(f"'{method}'", lifecycle)
            method_start = main_window.index(f'case "{method}"')
            next_case = main_window.find("\n      case ", method_start + 1)
            default_case = main_window.find("\n      default:", method_start + 1)
            candidates = [value for value in (next_case, default_case) if value >= 0]
            method_end = min(candidates)
            self.assertIn(
                "delegate.enqueueCoreProcessOperation",
                main_window[method_start:method_end],
            )
        self.assertNotIn('case "persistOwnedCoreRecord"', main_window)
        self.assertNotIn("'persistOwnedCoreRecord'", lifecycle)
        self.assertNotIn("Process.start(", lifecycle)
        self.assertNotIn("Process.killPid", lifecycle)
        self.assertNotIn("/bin/ps", lifecycle)
        self.assertNotIn("process.kill", lifecycle)
        self.assertNotIn("terminateMacosCoreProcess", lifecycle)

        awake = main_window.index("override func awakeFromNib()")
        acquire = main_window.index("delegate.acquireInstanceLease()", awake)
        engine = main_window.index("FlutterViewController()", awake)
        self.assertLess(acquire, engine)

        termination = app_delegate.index("override func applicationWillTerminate")
        drain = app_delegate.index("performCoreProcessOperationAndWait", termination)
        restore = app_delegate.index("restoreSavedProxyState()", termination)
        self.assertLess(drain, restore)

        begin = main_window.index('call.method == "beginProxyLifecycleTransaction"')
        end = main_window.index('call.method == "endProxyLifecycleTransaction"')
        self.assertIn(
            "delegate.performCoreProcessOperationAndWait",
            main_window[begin:end],
        )
        end_guard = main_window.index("guard\n        let arguments", end)
        self.assertIn(
            "delegate.enqueueCoreProcessOperation",
            main_window[end:end_guard],
        )

    def test_proxy_recovery_is_single_flight_and_unsafe_state_fails_closed(self) -> None:
        source = self.read(
            "SSRVPN_MacOS/lib/services/system_proxy_service.dart"
        )
        for token in (
            "Future<bool>? _clearSystemProxyInFlight",
            "return _clearSystemProxyInFlight ??= _runClearSystemProxy()",
            "_clearSystemProxyInFlight = null",
            "followLinks: false",
            "stat.size > _maxStateFileBytes",
            "stat.mode & _groupOrOtherWriteMask != 0",
            "无法确认代理归属，已保留恢复快照并阻止核心清理",
            "_runWithNativeProxyLifecycleLease(",
            "'beginProxyLifecycleTransaction'",
            "'endProxyLifecycleTransaction'",
            "_snapshotMetadataKeys.contains(service)",
            "_validatedSavedServiceStates(raw)",
            "_isValidProxyState(value['web'])",
        ):
            self.assertIn(token, source)


if __name__ == "__main__":
    unittest.main()
