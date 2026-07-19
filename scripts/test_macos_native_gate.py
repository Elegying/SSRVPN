from contextlib import ExitStack, redirect_stderr
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from typing import Optional
import unittest
from unittest.mock import patch

from scripts import macos_native_post_test_gate as post_test_gate


ROOT = Path(__file__).resolve().parents[1]


class MacosNativeGateTest(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def run_native_runner(
        self,
        *,
        crash_report_body: Optional[str] = None,
        preexisting_crash_report_body: Optional[str] = None,
        leave_test_host_running: bool = False,
        flutter_exit_code: int = 0,
        xcodebuild_exit_code: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            fake_bin = temporary / "bin"
            reports = temporary / "DiagnosticReports"
            fake_bin.mkdir()
            reports.mkdir()

            def write_executable(name: str, contents: str) -> None:
                path = fake_bin / name
                path.write_text(contents, encoding="utf-8")
                path.chmod(0o755)

            write_executable("uname", "#!/bin/sh\necho Darwin\n")
            write_executable(
                "flutter",
                "#!/bin/sh\nexit \"${FAKE_FLUTTER_EXIT_CODE:-0}\"\n",
            )
            write_executable(
                "xcodebuild",
                """#!/bin/sh
derived_data_path=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-derivedDataPath' ]; then
    shift
    derived_data_path="$1"
  fi
  shift
done
if [ -n "${FAKE_CRASH_REPORT_PATH:-}" ]; then
  printf '%s\n' "${FAKE_CRASH_REPORT_BODY:-}" > "$FAKE_CRASH_REPORT_PATH"
fi
if [ "${FAKE_LEAVE_TEST_HOST_RUNNING:-0}" = '1' ]; then
  printf '%s\n' \
    "54321 1 ${FAKE_PROCESS_UID} ${derived_data_path}/Build/Products/Debug/SSRVPN.app/Contents/MacOS/SSRVPN" \
    > "$FAKE_PROCESS_LIST_PATH"
fi
exit "${FAKE_XCODEBUILD_EXIT_CODE:-0}"
""",
            )

            process_list = temporary / "process-list.txt"
            process_list.write_text("", encoding="utf-8")

            if preexisting_crash_report_body is not None:
                (reports / "SSRVPN-2026-07-20-000001.ips").write_text(
                    preexisting_crash_report_body,
                    encoding="utf-8",
                )

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "TMPDIR": str(temporary),
                    "SSRVPN_DIAGNOSTIC_REPORTS_DIR": str(reports),
                    "SSRVPN_CRASH_REPORT_SETTLE_SECONDS": "0",
                    "SSRVPN_MACOS_GATE_TESTING": "1",
                    "SSRVPN_MACOS_PROCESS_LIST_FILE": str(process_list),
                    "FAKE_FLUTTER_EXIT_CODE": str(flutter_exit_code),
                    "FAKE_XCODEBUILD_EXIT_CODE": str(xcodebuild_exit_code),
                    "FAKE_PROCESS_LIST_PATH": str(process_list),
                    "FAKE_PROCESS_UID": str(os.getuid()),
                }
            )
            if crash_report_body is not None:
                environment.update(
                    {
                        "FAKE_CRASH_REPORT_PATH": str(
                            reports / "SSRVPN-2026-07-20-000002.ips"
                        ),
                        "FAKE_CRASH_REPORT_BODY": crash_report_body,
                    }
                )
            if leave_test_host_running:
                environment["FAKE_LEAVE_TEST_HOST_RUNNING"] = "1"
            return subprocess.run(
                ["bash", str(ROOT / "scripts/test-macos-native.sh")],
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def test_native_runner_executes_runner_tests_only_on_macos(self) -> None:
        runner = self.read("scripts/test-macos-native.sh")

        self.assertIn('[[ "$(uname -s)" != "Darwin" ]]', runner)
        self.assertIn("flutter build macos --debug --config-only --no-pub", runner)
        self.assertIn("xcodebuild test", runner)
        self.assertIn('-derivedDataPath "$DERIVED_DATA"', runner)
        self.assertIn("-only-testing:RunnerTests", runner)
        self.assertIn("-parallel-testing-enabled NO", runner)
        self.assertIn("-maximum-parallel-testing-workers 1", runner)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", runner)

        scheme = self.read(
            "SSRVPN_MacOS/macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme"
        )
        self.assertIn('parallelizable = "NO"', scheme)
        self.assertNotIn('parallelizable = "YES"', scheme)

    def test_native_runner_fails_when_test_host_writes_a_new_crash_report(self) -> None:
        result = self.run_native_runner(
            crash_report_body=(
                '{"procPath":"/private/tmp/Runner/Build/Products/Debug/'
                'SSRVPN.app/Contents/MacOS/SSRVPN"}'
            )
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("SSRVPN-2026-07-20-000002.ips", result.stdout)

    def test_native_runner_fails_closed_for_an_unclassifiable_new_report(self) -> None:
        result = self.run_native_runner(
            crash_report_body='{"path":"/usr/lib/libSystem.B.dylib"}'
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("could not be classified", result.stdout)

    def test_native_runner_ignores_preexisting_and_installed_app_reports(self) -> None:
        test_host_report = (
            '{"procPath":"/private/tmp/Runner/Build/Products/Debug/'
            'SSRVPN.app/Contents/MacOS/SSRVPN"}'
        )
        result = self.run_native_runner(
            preexisting_crash_report_body=test_host_report,
            crash_report_body=(
                '{"procPath":"/Applications/SSRVPN.app/Contents/MacOS/SSRVPN"}'
            ),
        )

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_native_runner_ignores_an_app_translocation_report(self) -> None:
        result = self.run_native_runner(
            crash_report_body=(
                '{"procPath":"/private/var/folders/test/AppTranslocation/'
                'ABC/d/SSRVPN.app/Contents/MacOS/SSRVPN"}'
            )
        )

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_native_runner_fails_when_a_new_test_host_remains_running(self) -> None:
        result = self.run_native_runner(leave_test_host_running=True)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("54321 1", result.stdout)
        self.assertIn("/Build/Products/Debug/SSRVPN.app", result.stdout)

    def test_native_runner_preserves_xcodebuild_failure_status(self) -> None:
        result = self.run_native_runner(xcodebuild_exit_code=17)

        self.assertEqual(result.returncode, 17, result.stdout)
        self.assertIn("Preserved macOS native test diagnostics", result.stdout)

    def test_native_runner_preserves_an_early_flutter_failure_status(self) -> None:
        result = self.run_native_runner(flutter_exit_code=23)

        self.assertEqual(result.returncode, 23, result.stdout)
        self.assertIn("Preserved macOS native test diagnostics", result.stdout)

    def test_post_test_gate_ignores_a_preexisting_report_completed_later(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            reports = temporary / "DiagnosticReports"
            reports.mkdir()
            report = reports / "SSRVPN-2026-07-20-000003.ips"
            report.write_text(
                '{"procPath":"/Applications/SSRVPN.app"}\n',
                encoding="utf-8",
            )
            baseline = post_test_gate.snapshot_reports(reports)
            report.write_text(
                '{"procPath":"/private/tmp/Test/Build/Products/Debug/'
                'SSRVPN.app/Contents/MacOS/SSRVPN"}\n',
                encoding="utf-8",
            )
            process_list = temporary / "process-list.txt"
            process_list.write_text("", encoding="utf-8")

            with redirect_stderr(io.StringIO()):
                status = post_test_gate.check_post_test_state(
                    reports,
                    baseline,
                    wait_seconds=0,
                    derived_data_path=temporary / "DerivedData",
                    baseline_process_list="",
                    process_list_file=process_list,
                )

            self.assertEqual(status, 0)

    def test_post_test_gate_waits_for_a_delayed_partial_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            reports = temporary / "DiagnosticReports"
            reports.mkdir()
            report = reports / "SSRVPN-2026-07-20-000004.ips"
            process_list = temporary / "process-list.txt"
            process_list.write_text("", encoding="utf-8")
            baseline = post_test_gate.snapshot_reports(reports)

            def finish_report() -> None:
                time.sleep(0.05)
                report.write_text(
                    '{"path":"/usr/lib/libSystem.B.dylib"}',
                    encoding="utf-8",
                )
                time.sleep(0.05)
                report.write_text(
                    '{"procPath":"/private/tmp/Test/Build/Products/Debug/'
                    'SSRVPN.app/Contents/MacOS/SSRVPN"}',
                    encoding="utf-8",
                )

            writer = threading.Thread(target=finish_report)
            writer.start()
            started = time.monotonic()
            try:
                with redirect_stderr(io.StringIO()):
                    status = post_test_gate.check_post_test_state(
                        reports,
                        baseline,
                        wait_seconds=0.5,
                        derived_data_path=temporary / "DerivedData",
                        baseline_process_list="",
                        process_list_file=process_list,
                    )
            finally:
                writer.join()

            self.assertEqual(status, 1)
            self.assertGreaterEqual(time.monotonic() - started, 0.09)

    def test_post_test_gate_detects_legacy_underscore_crash_reports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            reports = temporary / "DiagnosticReports"
            reports.mkdir()
            baseline = post_test_gate.snapshot_reports(reports)
            (reports / "SSRVPN_2026-07-20-000005.crash").write_text(
                "Path: /private/tmp/Test/Build/Products/Debug/"
                "SSRVPN.app/Contents/MacOS/SSRVPN\n",
                encoding="utf-8",
            )
            process_list = temporary / "process-list.txt"
            process_list.write_text("", encoding="utf-8")

            with redirect_stderr(io.StringIO()):
                status = post_test_gate.check_post_test_state(
                    reports,
                    baseline,
                    wait_seconds=0,
                    derived_data_path=temporary / "DerivedData",
                    baseline_process_list="",
                    process_list_file=process_list,
                )

            self.assertEqual(status, 1)

    def test_post_test_gate_reclassifies_reports_at_the_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            report = temporary / "SSRVPN-2026-07-20-000006.ips"
            process_list = temporary / "process-list.txt"
            process_list.write_text("", encoding="utf-8")
            report_snapshot = {str(report)}

            with ExitStack() as stack:
                stack.enter_context(patch.object(
                    post_test_gate,
                    "snapshot_reports",
                    side_effect=[report_snapshot, report_snapshot],
                ))
                stack.enter_context(patch.object(
                    post_test_gate,
                    "report_is_test_host",
                    side_effect=[None, True],
                ))
                stack.enter_context(redirect_stderr(io.StringIO()))
                status = post_test_gate.check_post_test_state(
                    temporary,
                    set(),
                    wait_seconds=0,
                    derived_data_path=temporary / "DerivedData",
                    baseline_process_list="",
                    process_list_file=process_list,
                )

            self.assertEqual(status, 1)

    def test_post_test_gate_only_matches_anchored_test_processes(self) -> None:
        uid = os.getuid()
        derived_data = Path("/private/tmp/CurrentDerivedData")
        test_host = (
            f"100 1 {uid} {derived_data}/Build/Products/Debug/"
            "SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        other_test_host = (
            f"101 1 {uid} /Users/test/Library/Developer/Xcode/DerivedData/"
            "Other/Build/Products/Debug/"
            "SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        installed_host = (
            f"102 1 {uid} /Applications/SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        translocated_host = (
            f"103 1 {uid} /private/var/folders/test/AppTranslocation/ABC/d/"
            "SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        argument_only = (
            f"104 1 {uid} /usr/bin/python3 check.py /private/tmp/Test/Build/"
            "Products/Debug/SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        temporary_core = f"105 1 {uid} /private/var/folders/test/T/AtlasCore"
        existing_core = f"106 1 {uid} /private/var/folders/existing/T/AtlasCore"
        private_tmp_host = (
            f"107 1 {uid} /private/tmp/XCTest-copy/"
            "SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        var_folder_host = (
            f"108 1 {uid} /private/var/folders/test/T/XCTest-copy/"
            "SSRVPN.app/Contents/MacOS/SSRVPN"
        )

        residual = post_test_gate.residual_test_processes(
            "\n".join(
                (
                    test_host,
                    other_test_host,
                    installed_host,
                    translocated_host,
                    argument_only,
                    temporary_core,
                    existing_core,
                    private_tmp_host,
                    var_folder_host,
                )
            ),
            uid,
            derived_data,
            baseline_process_list=existing_core,
        )

        self.assertEqual(
            residual,
            [test_host, temporary_core, private_tmp_host, var_folder_host],
        )
        self.assertFalse(
            post_test_gate.is_test_host_path(
                "/private/var/folders/test/AppTranslocation/ABC/d/"
                "SSRVPN.app/Contents/MacOS/SSRVPN"
            )
        )
        self.assertTrue(
            post_test_gate.is_test_host_path(
                "/private/var/folders/test/T/XCTest-copy/"
                "SSRVPN.app/Contents/MacOS/SSRVPN"
            )
        )

    def test_process_baseline_only_persists_relevant_test_executables(self) -> None:
        uid = os.getuid()
        test_host = (
            f"100 1 {uid} /private/var/folders/test/T/XCTest-copy/"
            "SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        temporary_core = f"101 1 {uid} /private/tmp/Test/AtlasCore"
        installed_host = (
            f"102 1 {uid} /Applications/SSRVPN.app/Contents/MacOS/SSRVPN"
        )
        unrelated_with_secret = (
            f"103 1 {uid} /usr/bin/example --token should-not-be-persisted"
        )
        other_uid_host = (
            f"104 1 {uid + 1} /private/tmp/Test/SSRVPN.app/Contents/MacOS/SSRVPN"
        )

        baseline = post_test_gate.process_baseline(
            "\n".join(
                (
                    test_host,
                    temporary_core,
                    installed_host,
                    unrelated_with_secret,
                    other_uid_host,
                )
            ),
            uid,
        )

        self.assertEqual(baseline, f"{test_host}\n{temporary_core}\n")
        self.assertNotIn("should-not-be-persisted", baseline)

    def test_dock_reopen_tests_do_not_animate_real_appkit_windows(self) -> None:
        runner_tests = self.read(
            "SSRVPN_MacOS/macos/RunnerTests/RunnerTests.swift"
        )
        dock_tests = runner_tests[
            runner_tests.index("func testDockReopenRevealsHiddenWindow") :
            runner_tests.index("func testTerminationPreservesMalformedPidFileFailClosed")
        ]

        self.assertNotIn("NSWindow(", dock_tests)
        self.assertNotIn("NSApplication.shared", dock_tests)
        self.assertIn("FakeWindowRevealTarget", dock_tests)
        self.assertIn("handleApplicationReopen", dock_tests)

        app_delegate = self.read("SSRVPN_MacOS/macos/Runner/AppDelegate.swift")
        reopen_handler = app_delegate[
            app_delegate.index("override func applicationShouldHandleReopen") :
            app_delegate.index("func revealMainWindow")
        ]
        self.assertIn("return handleApplicationReopen", reopen_handler)

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
