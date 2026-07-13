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
        self.assertIn("ActivationInProgress", recovery)
        self.assertIn("AutoConfigURL", recovery)
        self.assertIn("InternetSetOptionW", recovery)
        self.assertIn("RegDeleteTreeW", recovery)

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
        self.assertIn("Remove-Item -Path \\$backupPath", service)

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


if __name__ == "__main__":
    unittest.main()
