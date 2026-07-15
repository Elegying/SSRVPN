import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsRunOnceProxyRecoveryTest(unittest.TestCase):
    def test_guardian_mutex_name_matches_native_launcher(self) -> None:
        launcher = (
            ROOT / "SSRVPN_Windows" / "windows" / "runner" / "launcher_main.cpp"
        ).read_text(encoding="utf-8")
        service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        native_match = re.search(
            r'kGuardianMutexName\[\]\s*=\s*L"([^"]+)";', launcher, re.DOTALL
        )
        dart_match = re.search(
            r"_launcherGuardianMutexName\s*=\s*r'([^']+)';",
            service,
            re.DOTALL,
        )

        self.assertIsNotNone(native_match)
        self.assertIsNotNone(dart_match)
        native_name = native_match.group(1).replace("\\\\", "\\")
        self.assertEqual(native_name, dart_match.group(1))
        self.assertIn("CreateMutexW(nullptr, FALSE, kGuardianMutexName)", launcher)
        self.assertIn("[System.Threading.Mutex]::OpenExisting", service)
        self.assertIn("WaitOne(0)", service)
        self.assertIn("AbandonedMutexException", service)
        self.assertIn("ReleaseMutex()", service)

    def test_recovery_only_argument_is_exact_and_runs_before_app_startup(self) -> None:
        main = (
            ROOT / "SSRVPN_Windows" / "windows" / "runner" / "main.cpp"
        ).read_text(encoding="utf-8")
        branch = main.index('command_line_arguments[0] == "--recover-proxy-only"')

        self.assertIn("command_line_arguments.size() == 1", main[:branch])
        recovery_branch = main[branch : main.index("HANDLE instance_mutex")]
        self.assertIn(
            "bool safe_to_stop = RestoreOrConfirmOwnedWindowsProxySafeToStop()",
            recovery_branch,
        )
        self.assertIn("CreateMutexW(nullptr, TRUE, kAppInstanceMutexName)", recovery_branch)
        self.assertLess(
            recovery_branch.index("CreateMutexW"),
            recovery_branch.index("RestoreOrConfirmOwnedWindowsProxySafeToStop"),
        )
        self.assertIn("recovery_mutex_error == ERROR_ALREADY_EXISTS", recovery_branch)
        self.assertIn("::ReleaseMutex(recovery_mutex)", recovery_branch)
        self.assertIn("::CloseHandle(recovery_mutex)", recovery_branch)
        self.assertIn("while (!safe_to_stop)", recovery_branch)
        self.assertIn(
            "recovery_rearmed = RearmWindowsProxyRecoveryRunOnce()",
            recovery_branch,
        )
        self.assertIn("if (!recovery_rearmed)", recovery_branch)
        self.assertNotIn("break;", recovery_branch)
        self.assertIn("::Sleep(5000)", recovery_branch)
        self.assertIn("bool retry_logged = false", recovery_branch)
        self.assertEqual(
            recovery_branch.count(
                "proxy recovery and RunOnce rearm both failed; retrying"
            ),
            1,
        )
        self.assertIn("return EXIT_SUCCESS", recovery_branch)
        for startup_marker in (
            "CreateMutexW",
            "CoInitializeEx",
            "flutter::DartProject",
            "FlutterWindow window",
        ):
            self.assertLess(branch, main.index(startup_marker))

    def test_dart_and_native_share_one_crash_released_transaction_lock(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        recovery = (runner / "system_proxy_recovery.cpp").read_text(
            encoding="utf-8"
        )
        service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("system_proxy_transaction.lock", recovery)
        self.assertIn("system_proxy_transaction.lock", service)
        self.assertIn("LockFileEx", recovery)
        self.assertIn("UnlockFileEx", recovery)
        self.assertIn("FileLock.exclusive", service)
        self.assertIn("_withProxyTransactionLock(_clearSystemProxyUnlocked)", service)
        set_start = service.index("Future<bool> setSystemProxy")
        set_end = service.index("Future<bool> _setSystemProxyUnlocked", set_start)
        self.assertIn("_withProxyTransactionLock", service[set_start:set_end])

    def test_dart_cleanup_terminalizes_native_state_before_other_artifacts(self) -> None:
        service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        cleanup_start = service.index("Future<void> _deleteBackup()")
        cleanup_end = service.index(
            "Future<void> _writeNativeRecoveryBackup", cleanup_start
        )
        cleanup = service[cleanup_start:cleanup_end]

        json_terminal = cleanup.index("json['_activationInProgress'] = false")
        valid_zero = cleanup.index("-Name Valid -Type DWord -Value 0")
        flags_start = cleanup.index("foreach (\\$name in @(", valid_zero)
        restore_zero = cleanup.index("'RestoreInProgress'", flags_start)
        endpoint_zero = cleanup.index("'EndpointRestoreInProgress'", flags_start)
        activation_zero = cleanup.index("'ActivationInProgress'", flags_start)
        self.assertIn("-Name \\$name -Type DWord -Value 0", cleanup[flags_start:])
        native_delete = cleanup.index("Remove-Item -LiteralPath \\$backupPath")
        native_gate = cleanup.index("if (nativeResult.exitCode != 0)")
        runonce_delete = cleanup.index("Remove-ItemProperty -LiteralPath \\$runOncePath")
        json_delete = cleanup.rindex("await backupFile.delete()")
        self.assertLess(json_terminal, valid_zero)
        self.assertLess(valid_zero, restore_zero)
        self.assertLess(restore_zero, endpoint_zero)
        self.assertLess(endpoint_zero, activation_zero)
        self.assertLess(activation_zero, native_delete)
        self.assertLess(native_delete, native_gate)
        self.assertLess(native_gate, runonce_delete)
        self.assertLess(runonce_delete, json_delete)

    def test_tun_start_does_not_acquire_the_system_proxy(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")
        proxy_call = lifecycle.index("_proxyService.setSystemProxy(")
        tun_guard = lifecycle.rfind(
            "if (!settings.enableTun && !preserveSystemProxyRecovery)",
            0,
            proxy_call,
        )

        self.assertGreaterEqual(tun_guard, 0)
        self.assertLess(proxy_call, lifecycle.index("}", proxy_call))

    def test_installer_removes_runonce_with_terminal_recovery_state(self) -> None:
        installer = (
            ROOT
            / "SSRVPN_Windows"
            / "installer"
            / "stop_ssrvpn_processes.ps1"
        ).read_text(encoding="utf-8")
        cleanup_start = installer.index("function Remove-ProxyRecoveryState")
        cleanup_end = installer.index("function Test-RequiredProperties", cleanup_start)
        cleanup = installer[cleanup_start:cleanup_end]

        self.assertIn("Remove-ProxyRecoveryRunOnce", cleanup)
        self.assertIn("SSRVPNProxyRecovery", installer)
        runonce_cleanup_start = installer.index("function Remove-ProxyRecoveryRunOnce")
        runonce_cleanup_end = installer.index(
            "function Remove-ProxyRecoveryState", runonce_cleanup_start
        )
        runonce_cleanup = installer[runonce_cleanup_start:runonce_cleanup_end]
        self.assertIn("-ErrorAction Stop", runonce_cleanup)
        self.assertNotIn("SilentlyContinue", runonce_cleanup)
        json_terminal = cleanup.index("$json._activationInProgress = $false")
        json_gate = cleanup.index("if (-not $jsonTerminal)")
        native_invalidate = cleanup.index("-Name 'Valid' -Type DWord -Value 0")
        native_delete = cleanup.index("Remove-Item -Path $nativePath")
        native_gate = cleanup.index("if (-not $nativeTerminal)")
        json_delete = cleanup.rindex("Remove-Item -LiteralPath $jsonPath")
        runonce_delete = cleanup.index("Remove-ProxyRecoveryRunOnce")
        self.assertLess(json_terminal, json_gate)
        self.assertLess(json_gate, native_invalidate)
        self.assertLess(native_invalidate, native_delete)
        self.assertLess(native_delete, native_gate)
        self.assertLess(native_gate, json_delete)
        self.assertLess(json_delete, runonce_delete)

    def test_native_cleanup_knows_the_runonce_value(self) -> None:
        recovery = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "system_proxy_recovery.cpp"
        ).read_text(encoding="utf-8")

        self.assertIn("SSRVPNProxyRecovery", recovery)
        self.assertIn("RegDeleteValueW", recovery)
        rearm_start = recovery.index("bool RearmWindowsProxyRecoveryRunOnce()")
        rearm_end = recovery.index("bool RestoreOwnedWindowsProxy()")
        rearm = recovery[rearm_start:rearm_end]
        self.assertIn("GetModuleFileNameW", rearm)
        self.assertIn('L"\\\" --recover-proxy-only"', rearm)
        self.assertIn("RegSetValueExW", rearm)
        restore_start = recovery.index("bool RestoreOwnedWindowsProxyUnlocked()")
        no_backup_start = recovery.index(
            "if (backup_open_status != ERROR_SUCCESS)", restore_start
        )
        no_backup_end = recovery.index("DWORD valid = 0;", no_backup_start)
        no_backup = recovery[no_backup_start:no_backup_end]
        self.assertIn("IsOwnedWindowsProxySafeToStop", no_backup)
        self.assertIn("RemoveRecoveryRunOnce()", no_backup)
        confirmed_start = recovery.index(
            "if (!owned && !full_restore_pending) {"
        )
        confirmed_end = recovery.index(
            "DWORD original_proxy_enable = 0;", confirmed_start
        )
        confirmed_not_owned = recovery[confirmed_start:confirmed_end]
        self.assertIn("RemoveRecoveryArtifacts()", confirmed_not_owned)
        restore_failure_start = recovery.rindex("if (!settings_restored) {")
        restore_failure_end = recovery.rindex(
            "const bool artifacts_removed = RemoveRecoveryArtifacts();"
        )
        restore_failure = recovery[restore_failure_start:restore_failure_end]
        self.assertNotIn("RemoveRecoveryRunOnce", restore_failure)
        self.assertNotIn("RemoveRecoveryArtifacts", restore_failure)
        terminal_cleanup = recovery[restore_failure_end:]
        self.assertIn("journal_terminal || artifacts_removed", terminal_cleanup)


if __name__ == "__main__":
    unittest.main()
