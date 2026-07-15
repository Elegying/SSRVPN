import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsProxyShutdownRecoveryTest(unittest.TestCase):
    def test_native_shutdown_restores_only_owned_proxy(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        flutter_window = (runner / "flutter_window.cpp").read_text(encoding="utf-8")
        cmake = (runner / "CMakeLists.txt").read_text(encoding="utf-8")
        recovery = (runner / "system_proxy_recovery.cpp").read_text(
            encoding="utf-8"
        )

        self.assertIn("WM_ENDSESSION", flutter_window)
        self.assertIn("RestoreOwnedWindowsProxy", flutter_window)
        self.assertLess(
            flutter_window.index("RestoreOwnedWindowsProxy"),
            flutter_window.index("HandleTopLevelWindowProc"),
        )
        self.assertIn('"system_proxy_recovery.cpp"', cmake)
        self.assertIn("RuntimeProxyBackup", recovery)
        self.assertIn("OwnedProxyServer", recovery)
        self.assertIn("OwnedProxyOverride", recovery)
        self.assertIn("IsOwnedProxyServer", recovery)
        self.assertIn("kOwnedProxyOverride", recovery)
        self.assertIn("DisableOwnedProxyFingerprint", recovery)
        self.assertGreaterEqual(
            recovery.count('IsDwordZeroOrAbsent(settings, L"AutoDetect")'),
            2,
        )
        backup_check = recovery[
            recovery.index("const bool ownership_metadata_valid") : recovery.index(
                "if (!backup_valid)"
            )
        ]
        self.assertIn("IsOwnedProxyServer(owned_server)", backup_check)
        self.assertIn("owned_override == kOwnedProxyOverride", backup_check)
        invalid_backup = recovery[
            recovery.index("if (!backup_valid)") : recovery.index(
                "HKEY settings = nullptr"
            )
        ]
        self.assertIn("ownership_metadata_valid", invalid_backup)
        self.assertIn("DisableOwnedProxyFingerprint", invalid_backup)
        self.assertIn("ActivationInProgress", recovery)
        self.assertIn("AutoConfigURL", recovery)
        self.assertIn("InternetSetOptionW", recovery)
        self.assertIn("RegDeleteTreeW", recovery)
        self.assertIn("DisableOwnedProxyEndpoint", recovery)
        self.assertIn('SetDword(settings, L"ProxyEnable", 0)', recovery)

        restore_start = recovery.index("bool RestoreOwnedWindowsProxy()")
        restore_body = recovery[restore_start:]
        first_snapshot = restore_body.index("DWORD original_proxy_enable = 0;")
        full_snapshot = restore_body.index(
            "DWORD original_proxy_enable = 0;", first_snapshot + 1
        )
        full_restore = restore_body[full_snapshot:]
        mutation_tokens = (
            "SetDword(settings",
            "SetString(settings",
            "DeleteValueIfPresent(settings",
            "RestoreString(backup, settings",
        )
        first_mutation = min(
            full_restore.index(token)
            for token in mutation_tokens
            if token in full_restore
        )
        for token in (
            'ReadDword(backup, L"OriginalProxyEnable"',
            'ReadOptionalString(backup, L"HasProxyServer"',
            'ReadOptionalString(backup, L"HasProxyOverride"',
            'ReadOptionalString(backup, L"HasAutoConfigURL"',
            'ReadDword(backup, L"HasAutoDetect"',
            'ReadDword(backup, L"OriginalAutoDetect"',
        ):
            self.assertLess(full_restore.index(token), first_mutation)

        proxy_enable_write = full_restore.index(
            'SetDword(settings, L"ProxyEnable"'
        )
        self.assertGreater(
            proxy_enable_write,
            full_restore.index('RestorePreparedString(settings, has_proxy_server'),
        )
        self.assertGreater(
            proxy_enable_write,
            full_restore.index('RestorePreparedString(settings, has_auto_config_url'),
        )
        self.assertGreater(
            proxy_enable_write,
            full_restore.index('SetDword(settings, L"AutoDetect"'),
        )
        journal_write = restore_body.index(
            'SetDword(backup, L"RestoreInProgress", 1)'
        )
        self.assertLess(journal_write - full_snapshot, first_mutation)
        self.assertIn('restore_in_progress == 1', restore_body)

    def test_launcher_restores_proxy_after_the_primary_app_exits(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        main = (runner / "main.cpp").read_text(encoding="utf-8")
        launcher = (runner / "launcher_main.cpp").read_text(encoding="utf-8-sig")
        cmake = (runner / "CMakeLists.txt").read_text(encoding="utf-8")

        self.assertIn("return ERROR_ALREADY_EXISTS;", main)
        self.assertGreaterEqual(cmake.count('"system_proxy_recovery.cpp"'), 2)
        self.assertIn(
            'target_link_libraries(${LAUNCHER_TARGET} PRIVATE "advapi32.lib")',
            cmake,
        )
        self.assertIn(
            'target_link_libraries(${LAUNCHER_TARGET} PRIVATE "wininet.lib")',
            cmake,
        )

        exit_read = launcher.index("GetExitCodeProcess")
        duplicate_guard = launcher.index("exit_code != ERROR_ALREADY_EXISTS")
        restore = launcher.index("RestoreOwnedWindowsProxy()")
        self.assertLess(exit_read, duplicate_guard)
        self.assertLess(duplicate_guard, restore)
        self.assertIn("exit_code = EXIT_SUCCESS", launcher[restore:])

        message_loop_end = main.index(
            'startup_diagnostics::Log(L"message loop ended")'
        )
        final_restore = main.index("RestoreOwnedWindowsProxy()", message_loop_end - 100)
        window_destroy = main.index("window.Destroy()", message_loop_end)
        com_uninitialize = main.index("::CoUninitialize()", window_destroy)
        normal_shutdown = main.index(
            "startup_diagnostics::MarkNormalShutdown()", com_uninitialize
        )
        self.assertLess(final_restore, message_loop_end)
        self.assertLess(message_loop_end, window_destroy)
        self.assertLess(window_destroy, com_uninitialize)
        self.assertLess(com_uninitialize, normal_shutdown)

    def test_launcher_contains_and_cleans_up_the_primary_process_tree(self) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8-sig")

        self.assertIn("CreateJobObjectW", launcher)
        self.assertIn("CREATE_SUSPENDED", launcher)
        self.assertIn("AssignProcessToJobObject", launcher)
        self.assertIn("ResumeThread", launcher)
        self.assertIn("TerminateJobObject", launcher)
        restore = launcher.index("RestoreOwnedWindowsProxy()")
        terminate = launcher.index("TerminateJobObject", restore)
        self.assertLess(restore, terminate)
        self.assertNotIn("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", launcher)

    def test_in_app_installer_handoff_cannot_fall_back_into_the_job(self) -> None:
        handoff = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "windows_detached_installer_launcher.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("WindowsProcessCommand('explorer.exe', [path])", handoff)
        self.assertIn("GetShellWindow", handoff)
        self.assertIn("if (!shellAvailable())", handoff)
        self.assertNotIn("powershell.exe", handoff.lower())
        self.assertNotIn("Start-Process", handoff)

    def test_windows_powershell_calls_force_utf8_output(self) -> None:
        helper = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "src"
            / "services"
            / "windows_powershell.dart"
        ).read_text(encoding="utf-8")
        proxy_service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("[Console]::OutputEncoding", helper)
        self.assertIn("$OutputEncoding = [Console]::OutputEncoding", helper)
        self.assertIn("$ErrorActionPreference = 'Stop'", helper)
        self.assertIn("windowsPowerShellUtf8Script(script)", proxy_service)
        self.assertIn("windowsPowerShellUtf8Script(script)", lifecycle)

    def test_windows_process_logs_tolerate_malformed_utf8(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        self.assertNotIn(".transform(utf8.decoder)", lifecycle)
        self.assertGreaterEqual(
            lifecycle.count("Utf8Decoder(allowMalformed: true)"),
            4,
        )

    def test_native_chinese_sources_compile_as_utf8(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        cmake = (runner / "CMakeLists.txt").read_text(encoding="utf-8")
        launcher = (runner / "launcher_main.cpp").read_bytes()

        self.assertIn('target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")', cmake)
        self.assertIn('target_compile_options(${LAUNCHER_TARGET} PRIVATE "/utf-8")', cmake)
        self.assertTrue(launcher.startswith(b"\xef\xbb\xbf"))

    def test_dart_persists_native_backup_before_enabling_proxy(self) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")

        backup = service.index("await _writeBackup(snapshot, proxyServer)")
        enable = service.index("Set-ItemProperty -Path \\$regPath -Name ProxyEnable")
        self.assertLess(backup, enable)
        for token in (
            "Set-ItemProperty -Path \\$regPath -Name ProxyServer",
            "Set-ItemProperty -Path \\$regPath -Name ProxyOverride",
            "Set-ItemProperty -Path \\$regPath -Name AutoDetect",
            "Remove-ItemProperty -Path \\$regPath -Name AutoConfigURL",
        ):
            self.assertLess(service.index(token), enable)
        self.assertIn("await _writeNativeRecoveryBackup", service)
        self.assertIn("RuntimeProxyBackup", service)
        self.assertIn("ActivationInProgress", service)
        self.assertIn("await _markActivationComplete()", service)
        self.assertIn("Remove-Item -LiteralPath \\$backupPath", service)

    def test_dart_native_backup_cleanup_is_idempotent_when_missing(self) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        delete_cleanup = service[
            service.index("Future<void> _deleteBackup") : service.index(
                "Future<void> _writeNativeRecoveryBackup"
            )
        ]
        write_cleanup = service[
            service.index("Future<void> _writeNativeRecoveryBackup") : service.index(
                "Future<void> _markActivationComplete"
            )
        ]

        guard = "if (Test-Path -LiteralPath \\$backupPath)"
        for operation, cleanup in (
            ("delete", delete_cleanup),
            ("write", write_cleanup),
        ):
            with self.subTest(operation=operation):
                self.assertIn(guard, cleanup)
                self.assertLess(cleanup.index(guard), cleanup.index("Remove-Item"))
        self.assertLess(
            write_cleanup.index("Remove-Item"),
            write_cleanup.index("New-Item"),
        )

    def test_dart_marks_proxy_restore_before_the_first_registry_write(
        self,
    ) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")

        full_restore = service[
            service.index("Future<bool> _restoreSnapshot") : service.index(
                "Future<bool> _restoreOwnedEndpoint"
            )
        ]
        endpoint_restore = service[
            service.index("Future<bool> _restoreOwnedEndpoint") : service.index(
                "Future<void> _writeBackup"
            )
        ]
        self.assertLess(
            full_restore.index("RestoreInProgress"),
            full_restore.index("Set-ItemProperty -Path \\$regPath"),
        )
        self.assertLess(
            endpoint_restore.index("EndpointRestoreInProgress"),
            endpoint_restore.index("Set-ItemProperty -Path \\$regPath"),
        )

    def test_connect_retries_pending_proxy_recovery_in_the_same_action(self) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")
        app = (ROOT / "SSRVPN_Windows" / "lib" / "app.dart").read_text(
            encoding="utf-8"
        )
        home = (
            ROOT
            / "packages"
            / "ssrvpn_shared"
            / "lib"
            / "desktop_ui"
            / "screens"
            / "desktop_home_screen_part.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("Future<bool> retryPendingRecovery()", service)
        self.assertIn("await initialize(dataDir)", service)
        self.assertIn("Future<bool> recoverPendingSystemProxy()", lifecycle)
        tray_connect = app[
            app.index("Future<void> _handleTrayConnectToggle()") : app.index(
                "String? _defaultNodeName()"
            )
        ]
        tray_generation = tray_connect.index("requestConnectionIntent(true)")
        tray_recovery = tray_connect.index("recoverPendingSystemProxy")
        self.assertLess(tray_generation, tray_recovery)
        self.assertIn(
            "isConnectionIntentCurrent",
            tray_connect[tray_recovery:],
        )
        home_connect = home[
            home.index("Future<void> _handleConnectToggle()") : home.index(
                "@override\n  Widget build"
            )
        ]
        home_generation = home_connect.index("requestConnectionIntent(true)")
        home_recovery = home_connect.index("recoverPendingSystemProxy")
        self.assertLess(home_generation, home_recovery)
        self.assertIn(
            "isConnectionIntentCurrent",
            home_connect[home_recovery:],
        )

    def test_windows_surfaces_runtime_ports_and_recovers_one_core_exit(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")
        app = (ROOT / "SSRVPN_Windows" / "lib" / "app.dart").read_text(
            encoding="utf-8"
        )
        summary = (
            ROOT
            / "packages"
            / "ssrvpn_shared"
            / "lib"
            / "desktop_ui"
            / "widgets"
            / "desktop_home_status_widgets_part.dart"
        ).read_text(encoding="utf-8")
        tray = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "tray_manager.dart"
        ).read_text(encoding="utf-8")

        tray_connect = app[
            app.index("Future<void> _handleTrayConnectToggle()") : app.index(
                "String? _defaultNodeName()"
            )
        ]
        self.assertIn("lastRuntimePortAdjustmentMessage", tray_connect)
        self.assertIn("_presentRuntimeNotice", tray_connect)
        self.assertIn("runtimeProxyPort", summary)
        self.assertIn("runtimeProxyPort", tray)
        self.assertIn("HTTP 代理：127.0.0.1:$port", tray)
        self.assertIn("enabled: false", tray)
        self.assertIn("HTTP 127.0.0.1:$port", app)
        self.assertIn("CoreRecoveryPolicy(maxAttempts: 1)", lifecycle)
        self.assertIn("Future<bool> start() => _start();", lifecycle)
        self.assertIn("_start(automaticRecovery: true)", lifecycle)
        self.assertLess(
            lifecycle.index("_unexpectedExitRecoveryPolicy.reset()"),
            lifecycle.index("final current = _startOperation"),
        )
        self.assertIn("captureAutomaticRestartIntent()", lifecycle)
        self.assertIn("isConnectionIntentCurrent", lifecycle)
        self.assertIn("核心异常退出，正在自动恢复", lifecycle)
        self.assertIn("if (restarted && isRunning)", lifecycle)
        self.assertIn("核心已自动恢复", lifecycle)
        self.assertIn("自动恢复失败", lifecycle)
        self.assertIn("onRuntimeNotice", app)


if __name__ == "__main__":
    unittest.main()
