import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsInstallerConfigTest(unittest.TestCase):
    def test_installer_code_does_not_start_continuation_lines_with_brackets(
        self,
    ) -> None:
        script = (ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss").read_text(
            encoding="utf-8"
        )
        code = script.split("[Code]", 1)[1]

        self.assertNotRegex(code, re.compile(r"^\s+\[[^\]]+\]", re.MULTILINE))

    def test_installer_always_creates_desktop_shortcut(self) -> None:
        script = (ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss").read_text(
            encoding="utf-8"
        )

        desktop_icon = next(
            line
            for line in script.splitlines()
            if line.startswith('Name: "{autodesktop}\\SSRVPN"')
        )
        self.assertNotIn("Tasks:", desktop_icon)
        self.assertNotIn('Name: "desktopicon"', script)

    def test_installer_closes_ssrvpn_and_installs_per_user(self) -> None:
        script = (ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss").read_text(
            encoding="utf-8"
        )

        self.assertIn(r"DefaultDirName={localappdata}\Programs\SSRVPN", script)
        self.assertIn("DisableDirPage=yes", script)
        self.assertIn("UsePreviousAppDir=no", script)
        self.assertIn("PrivilegesRequired=lowest", script)
        self.assertIn("CloseApplications=force", script)
        self.assertIn("RestartApplications=no", script)
        self.assertNotIn("ChineseSimplified.isl", script)
        self.assertIn("ssrvpn_windows_app.exe", script)
        self.assertIn("ssrvpn_windows.exe", script)
        self.assertNotRegex(script, r"taskkill[^\n]+mihomo\.exe")
        run_entry = next(
            line for line in script.splitlines() if line.startswith('Filename: "{app}')
        )
        self.assertNotIn("postinstall", run_entry)
        self.assertNotIn("skipifsilent", run_entry)

    def test_installer_ignores_portable_copies_and_blocks_unsafe_rebuild(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")

        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1]
        self.assertLess(
            prepare.index("StopSsrvpnProcesses"),
            prepare.index("PrepareInstallDirectory"),
        )
        self.assertIn("Result := '';", prepare)
        self.assertIn("无法安全备份或恢复现有数据", prepare)
        self.assertIn("CanLaunchAfterRestore", installer)
        self.assertIn("旧数据尚未安全恢复", installer)
        self.assertNotIn("DiscoverPortableData", installer)
        self.assertNotIn("MigratePortableData", installer)
        self.assertNotIn("migrate_portable_data.ps1", installer)
        self.assertNotIn("多个便携", installer)
        self.assertIn("restartreplace", installer)
        self.assertIn("overwritereadonly", installer)

    def test_installer_rebuilds_only_active_directory_and_restores_data(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        prepare = (installer_root / "prepare_install_directory.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("prepare_install_directory.ps1", installer)
        self.assertIn("-InstallDir", installer)
        self.assertIn("-DataDir", installer)
        self.assertIn("-RecoveryRoot", installer)
        self.assertIn("-StateFile", installer)
        self.assertIn("-Restore", installer)
        self.assertIn("InstallDataRestoreRequired", installer)
        self.assertIn("DirectoryResult = 10", installer)
        self.assertIn("if InstallDataRestoreRequired then", installer)
        self.assertIn("subscriptions.json", prepare)
        self.assertIn("files = $backupManifest", prepare)
        self.assertIn("ConvertTo-Json -Depth 4", prepare)
        self.assertIn("recovery manifest is missing", prepare)
        self.assertIn("source hash differs from the manifest", prepare)
        self.assertIn("Get-FileHash", prepare)
        self.assertIn("Test-ChildPath", prepare)
        self.assertIn("Get-PathItem", prepare)
        self.assertIn("[System.IO.Directory]::Delete($installPath, $false)", prepare)
        self.assertIn("Move-Item -LiteralPath $installPath", prepare)
        self.assertIn("New-Item -ItemType Directory -Path $installPath", prepare)
        self.assertIn("exit 10", prepare)
        self.assertNotIn("GetFolderPath('Desktop')", prepare)
        self.assertNotIn("Join-Path $env:USERPROFILE 'Downloads'", prepare)

        writable_upgrade = prepare.index(
            "if ((Test-Path -LiteralPath $installPath -PathType Container)"
        )
        prior_recovery = prepare.index(
            "# Finish a recoverable prior attempt before evaluating the current directory."
        )
        self.assertLess(writable_upgrade, prior_recovery)

    def test_installer_cleanup_is_path_exact_and_best_effort(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        stopper = (installer_root / "stop_ssrvpn_processes.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("stop_ssrvpn_processes.ps1", installer)
        self.assertIn("StopResult := StopSsrvpnProcesses", installer)
        self.assertIn("Result := '';", installer)
        self.assertIn("/F", stopper)
        self.assertIn("/T", stopper)
        self.assertIn("ExecutablePath", stopper)
        self.assertIn("SessionId", stopper)
        self.assertIn("remainingApps", stopper)
        self.assertIn("remainingCores", stopper)
        self.assertIn("Restore-OwnedSystemProxy", stopper)
        self.assertLess(
            stopper.index("Restore-OwnedSystemProxy"),
            stopper.index("& $taskkill /F /T /PID"),
        )
        self.assertIn("system_proxy_backup.json", stopper)
        self.assertIn("RuntimeProxyBackup", stopper)
        self.assertIn("Write-NativeRestoreJournal", stopper)
        self.assertIn("RestoreInProgress", stopper)
        self.assertIn("ActivationInProgress", stopper)
        self.assertIn("InstalledCorePath", stopper)
        self.assertIn("Test-ExactPath", stopper)
        self.assertIn("Stop-Process -Id $core.ProcessId", stopper)
        runtime_test = (
            ROOT / "scripts" / "test_windows_installer_runtime.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("ForceRebuild", runtime_test)
        self.assertIn("unrelated mihomo process was incorrectly stopped", runtime_test)
        restore = stopper.split("function Restore-OwnedSystemProxy", 1)[1]
        self.assertLess(
            restore.index("Write-NativeRestoreJournal"),
            restore.index("Set-OrRemoveRegistryValue -Path $regPath"),
        )
        self.assertNotRegex(stopper, r"Stop-Process\s+-Name\s+['\"]?mihomo")

    def test_release_pipeline_publishes_installer_and_checksum(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        required = {
            "tool\\build_installer.ps1",
            "installer\\prepare_install_directory.ps1",
            "installer\\stop_ssrvpn_processes.ps1",
            "SSRVPN_Windows/SSRVPN_Setup.exe",
            "SSRVPN_Windows/SSRVPN_Setup.exe.sha256",
        }
        for value in required:
            self.assertIn(value, release)

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        for value in required:
            self.assertIn(value, ci)

    def test_portable_checksum_uses_cross_platform_line_endings(self) -> None:
        package_script = (
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1"
        ).read_text(encoding="utf-8")
        checksum_block = package_script.split(
            "$zipHash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256", 1
        )[1]

        self.assertIn("[System.IO.File]::WriteAllText", checksum_block)
        self.assertIn('"$($zipHash.Hash.ToLower())  SSRVPN.zip`n"', checksum_block)
        self.assertNotIn("Set-Content -LiteralPath $zipHashPath", checksum_block)

    def test_windows_update_checker_selects_the_installer(self) -> None:
        service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "update_service.dart"
        ).read_text(encoding="utf-8")

        self.assertRegex(service, re.compile(r"assetExtension:\s*'\.exe'"))

    def test_windows_runtime_records_exact_core_pid_for_safe_cleanup(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("mihomo.pid", lifecycle)
        self.assertIn("await _writeCorePid(startedProcess.pid)", lifecycle)
        self.assertIn("await _deleteCorePid()", lifecycle)
        self.assertNotIn("Where-Object { \\$_.ExecutablePath -eq \\$target }", lifecycle)

    def test_portable_launcher_explains_complete_extraction(self) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8")

        self.assertIn("请完整解压 ZIP", launcher)
        self.assertIn("不能只复制 ssrvpn_windows.exe", launcher)


if __name__ == "__main__":
    unittest.main()
