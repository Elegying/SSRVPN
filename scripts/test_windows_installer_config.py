import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsInstallerConfigTest(unittest.TestCase):
    def test_installer_closes_ssrvpn_and_installs_per_user(self) -> None:
        script = (ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss").read_text(
            encoding="utf-8"
        )

        self.assertIn(r"DefaultDirName={localappdata}\Programs\SSRVPN", script)
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

    def test_installer_discovers_then_stops_before_atomic_migration(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        migration = (installer_root / "migrate_portable_data.ps1").read_text(
            encoding="utf-8"
        )

        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1]
        self.assertLess(prepare.index("DiscoverPortableData"), prepare.index("StopSsrvpnProcesses"))
        self.assertLess(prepare.index("StopSsrvpnProcesses"), prepare.index("MigratePortableData"))
        self.assertIn("function DiscoverPortableData: Boolean;", installer)
        self.assertIn("function MigratePortableData: Boolean;", installer)
        self.assertIn("if not DiscoverPortableData then", prepare)
        self.assertIn("if not MigratePortableData then", prepare)
        self.assertIn("便携版数据迁移失败", prepare)
        self.assertIn("Name = 'ssrvpn_windows_app.exe'", migration)
        self.assertIn("subscriptions.json", migration)
        self.assertIn("-not (Test-Path -LiteralPath $destinationFile)", migration)
        self.assertIn("[switch]$DiscoverOnly", migration)
        self.assertIn("[string]$StateFile", migration)
        self.assertIn("Get-FileHash", migration)
        self.assertIn("Move-Item -LiteralPath $tempFile", migration)
        self.assertNotRegex(migration, r"Copy-Item[^\n]+\\\*")

    def test_installer_can_find_an_exited_portable_copy(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        migration = (installer_root / "migrate_portable_data.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("-SetupSource", installer)
        self.assertIn("[string]$SetupSource", migration)
        self.assertIn("[Environment]::GetFolderPath('Desktop')", migration)
        self.assertIn("Join-Path $HOME 'Downloads'", migration)
        self.assertIn("ssrvpn_windows_app.exe", migration)
        self.assertIn("Multiple portable SSRVPN data directories", migration)
        self.assertNotIn("Get-SourceScore", migration)

    def test_installer_blocks_upgrade_when_its_process_tree_survives(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        stopper = (installer_root / "stop_ssrvpn_processes.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("stop_ssrvpn_processes.ps1", installer)
        self.assertIn("if not StopSsrvpnProcesses then", installer)
        self.assertIn("Result :=", installer)
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
        self.assertIn("InstalledCorePidPath", stopper)
        self.assertIn("Get-RecordedCore", stopper)
        self.assertNotIn("$corePaths += [System.IO.Path]::GetFullPath($InstalledCorePath)", stopper)
        runtime_test = (
            ROOT / "scripts" / "test_windows_installer_runtime.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("Ambiguous portable sources were not rejected", runtime_test)
        self.assertIn("unrecorded mihomo process was incorrectly stopped", runtime_test)
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
            "installer\\migrate_portable_data.ps1",
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
