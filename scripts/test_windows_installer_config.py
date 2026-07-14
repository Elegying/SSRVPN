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
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        script = (installer_root / "SSRVPN.iss").read_text(
            encoding="utf-8"
        )

        self.assertIn(r"DefaultDirName={localappdata}\Programs\SSRVPN", script)
        self.assertIn("DisableDirPage=yes", script)
        self.assertIn("UsePreviousAppDir=no", script)
        self.assertIn("PrivilegesRequired=lowest", script)
        self.assertNotIn("PrivilegesRequired=admin", script)
        self.assertNotRegex(
            script,
            re.compile(r"DefaultDirName=\{pf(?:32|64)?\}", re.I),
        )
        self.assertIn("CloseApplications=force", script)
        self.assertIn("RestartApplications=no", script)
        self.assertIn(
            r'MessagesFile: "{#ProjectDir}\installer\languages\ChineseSimplified.isl"',
            script,
        )
        self.assertIn(
            r"InfoBeforeFile={#ProjectDir}\installer\overwrite_notice.zh-CN.txt",
            script,
        )
        language = (installer_root / "languages" / "ChineseSimplified.isl").read_text(
            encoding="utf-8-sig"
        )
        self.assertTrue(
            (installer_root / "SSRVPN.iss").read_bytes().startswith(b"\xef\xbb\xbf")
        )
        self.assertTrue(
            (installer_root / "languages" / "ChineseSimplified.isl")
            .read_bytes()
            .startswith(b"\xef\xbb\xbf")
        )
        self.assertTrue(
            (installer_root / "overwrite_notice.zh-CN.txt")
            .read_bytes()
            .startswith(b"\xef\xbb\xbf")
        )
        self.assertIn("LanguageName=简体中文", language)
        notice = (installer_root / "overwrite_notice.zh-CN.txt").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("永久删除当前 Windows 用户的 SSRVPN 旧数据", notice)
        self.assertIn("不会搜索、备份或恢复", notice)
        self.assertIn("ssrvpn_windows_app.exe", script)
        self.assertIn("ssrvpn_windows.exe", script)
        self.assertNotRegex(script, r"taskkill[^\n]+mihomo\.exe")
        run_entry = next(
            line for line in script.splitlines() if line.startswith('Filename: "{app}')
        )
        self.assertNotIn("postinstall", run_entry)
        self.assertNotIn("skipifsilent", run_entry)

    def test_installer_ignores_portable_data_and_blocks_before_destructive_copy(
        self,
    ) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")

        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1]
        self.assertIn("StopResult := StopSsrvpnProcesses", prepare)
        self.assertIn("if StopResult = 0 then", prepare)
        self.assertIn("无法关闭正在运行的 SSRVPN", prepare)
        self.assertNotIn("PrepareInstallDirectory", installer)
        self.assertNotIn("CanLaunchAfterRestore", installer)
        self.assertNotIn("无法安全备份或恢复现有数据", installer)
        self.assertNotIn("旧数据尚未安全恢复", installer)
        self.assertNotIn("DiscoverPortableData", installer)
        self.assertNotIn("MigratePortableData", installer)
        self.assertNotIn("migrate_portable_data.ps1", installer)
        self.assertNotIn("多个便携", installer)
        self.assertNotIn("restartreplace", installer)
        self.assertIn("overwritereadonly", installer)

    def test_installer_discards_all_previous_state_before_copying_files(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")

        self.assertIn("[InstallDelete]", installer)
        self.assertLess(installer.index("[InstallDelete]"), installer.index("[Files]"))
        self.assertIn('Type: filesandordirs; Name: "{app}\\*"', installer)
        self.assertIn(
            'Type: filesandordirs; '
            'Name: "{localappdata}\\SSRVPN\\ssrvpn"',
            installer,
        )
        self.assertIn(
            'Type: files; '
            'Name: "{localappdata}\\SSRVPN\\window_state.json"',
            installer,
        )
        self.assertIn(
            'Type: filesandordirs; '
            'Name: "{localappdata}\\SSRVPN\\installer-recovery"',
            installer,
        )
        self.assertIn(
            'Type: files; '
            'Name: "{localappdata}\\SSRVPN\\installer\\rebuild-state.json"',
            installer,
        )
        self.assertIn(
            'Type: dirifempty; Name: "{localappdata}\\SSRVPN\\installer"',
            installer,
        )
        self.assertFalse((installer_root / "prepare_install_directory.ps1").exists())
        self.assertNotIn("prepare_install_directory.ps1", installer)
        self.assertNotIn("InstallDataRestore", installer)
        self.assertNotIn("RestoreInstallData", installer)

    def test_installer_cleanup_is_path_exact_and_best_effort(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        stopper = (installer_root / "stop_ssrvpn_processes.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("stop_ssrvpn_processes.ps1", installer)
        self.assertIn("StopResult := StopSsrvpnProcesses", installer)
        self.assertIn("if StopResult = 0 then", installer)
        self.assertIn("/F", stopper)
        self.assertIn("/T", stopper)
        self.assertIn("ExecutablePath", stopper)
        self.assertIn("SessionId", stopper)
        self.assertIn("remainingApps", stopper)
        self.assertIn("remainingCores", stopper)
        self.assertIn("exit 2", stopper)
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
        self.assertIn("Test-RecoveryState", stopper)
        self.assertIn("Repair-InvalidProxyRecoveryState", stopper)
        invalid_repair = stopper.split(
            "function Repair-InvalidProxyRecoveryState", 1
        )[1].split("function Set-OrRemoveRegistryValue", 1)[0]
        self.assertIn("Test-OwnedProxyServer", invalid_repair)
        self.assertIn("$script:OwnedProxyOverride", invalid_repair)
        self.assertIn("ProxyEnable -Type DWord -Value 0", invalid_repair)
        self.assertIn("Remove-ProxyRecoveryState", invalid_repair)
        restore = stopper.split("function Restore-OwnedSystemProxy", 1)[1]
        self.assertLess(
            restore.index("Repair-InvalidProxyRecoveryState"),
            restore.index("$regPath"),
        )
        self.assertIn("Test-OwnedProxyServer", stopper)
        self.assertIn("Test-DwordFlag", stopper)
        self.assertIn("Test-BooleanValue", stopper)
        self.assertIn("$nativeFlagNames", stopper)
        self.assertIn("$jsonBooleanNames", stopper)
        self.assertIn("InstalledCorePath", stopper)
        self.assertIn("InstalledAppPath", stopper)
        self.assertIn("InstalledLauncherPath", stopper)
        self.assertIn(
            "Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledAppPath",
            stopper,
        )
        self.assertIn(
            "Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledLauncherPath",
            stopper,
        )
        self.assertIn("Test-ExactPath", stopper)
        self.assertIn("Stop-Process -Id $core.ProcessId", stopper)
        runtime_test = (
            ROOT / "scripts" / "test_windows_installer_runtime.ps1"
        ).read_text(encoding="utf-8")
        self.assertNotIn("prepare_install_directory.ps1", runtime_test)
        self.assertIn("unrelated mihomo process was incorrectly stopped", runtime_test)
        restore = stopper.split("function Restore-OwnedSystemProxy", 1)[1]
        self.assertLess(
            restore.index("Write-NativeRestoreJournal"),
            restore.index("Set-OrRemoveRegistryValue -Path $regPath"),
        )
        self.assertNotRegex(stopper, r"Stop-Process\s+-Name\s+['\"]?mihomo")
        self.assertIn(
            "Get-Content -LiteralPath $jsonPath -Encoding UTF8 -Raw",
            stopper,
        )

    def test_uninstaller_restores_proxy_and_stops_only_its_installation(
        self,
    ) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        stopper = (installer_root / "stop_ssrvpn_processes.ps1").read_text(
            encoding="utf-8"
        )
        smoke = (ROOT / "scripts" / "test_windows_installer_package.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("function InitializeUninstall(): Boolean;", installer)
        self.assertIn("{app}\\installer\\stop_ssrvpn_processes.ps1", installer)
        self.assertIn("InstalledAppPath", installer)
        self.assertIn("InstalledLauncherPath", installer)
        uninstall = installer.split("function InitializeUninstall(): Boolean;", 1)[1]
        self.assertIn("StopSsrvpnProcesses", uninstall)
        self.assertIn("Result := StopResult = 0", uninstall)
        self.assertIn("卸载尚未删除程序文件", uninstall)

        self.assertNotIn("-File $stopper", smoke)
        self.assertIn("uninstaller must stop the running installed app", smoke)

        journal = stopper.split("function Write-NativeRestoreJournal", 1)[1]
        journal = journal.split("function Notify-WinInetProxyChange", 1)[0]
        self.assertLess(
            journal.index("Valid -Type DWord -Value 0"),
            journal.index("foreach ($entry in $values.GetEnumerator())"),
        )
        self.assertGreater(
            journal.rindex("Valid -Type DWord -Value 1"),
            journal.index("foreach ($entry in $values.GetEnumerator())"),
        )

    def test_windows_installer_scripts_are_powershell_51_compatible(self) -> None:
        scripts = sorted((ROOT / "SSRVPN_Windows").rglob("*.ps1"))
        scripts.extend(sorted((ROOT / "scripts").glob("*.ps1")))
        incompatible_split_path = re.compile(
            r"\bSplit-Path\b(?=[^\r\n]*-LiteralPath\b)"
            r"(?=[^\r\n]*-Parent\b)[^\r\n]*",
            re.I | re.M,
        )

        self.assertTrue(scripts)
        for script_path in scripts:
            with self.subTest(script=script_path.name):
                self.assertNotRegex(
                    script_path.read_text(encoding="utf-8"),
                    incompatible_split_path,
                )

    def test_windows_powershell_sources_are_ascii_and_raw_reads_are_explicit(
        self,
    ) -> None:
        scripts = sorted((ROOT / "SSRVPN_Windows").rglob("*.ps1"))
        scripts.extend(sorted((ROOT / "scripts").glob("*.ps1")))
        raw_read = re.compile(r"\bGet-Content\b[^\r\n]*\s-Raw\b", re.I)

        self.assertTrue(scripts)
        for script_path in scripts:
            with self.subTest(script=script_path.relative_to(ROOT)):
                source = script_path.read_bytes()
                self.assertEqual(
                    source,
                    source.decode("ascii").encode("ascii"),
                    "PowerShell 5.1 misdecodes BOM-less non-ASCII source; "
                    "build localized messages from ASCII code points instead",
                )
                text = source.decode("ascii")
                for match in raw_read.finditer(text):
                    self.assertRegex(
                        match.group(0),
                        re.compile(r"\s-Encoding\s+", re.I),
                        f"Get-Content -Raw needs an explicit encoding: "
                        f"{match.group(0)}",
                    )

    def test_windows_workflows_fail_fast_after_each_powershell_51_process(
        self,
    ) -> None:
        workflows = [
            ROOT / ".github" / "workflows" / "ci.yml",
            ROOT / ".github" / "workflows" / "release.yml",
        ]
        invocation = re.compile(r"(?m)^\s*powershell\.exe\b[^\r\n]*$")
        exit_check = "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"

        for workflow_path in workflows:
            workflow = workflow_path.read_text(encoding="utf-8")
            matches = list(invocation.finditer(workflow))
            self.assertTrue(matches, workflow_path.name)
            for match in matches:
                following_lines = workflow[match.end() :].splitlines()
                next_command = next(
                    (line.strip() for line in following_lines if line.strip()), ""
                )
                with self.subTest(
                    workflow=workflow_path.name,
                    command=match.group(0).strip(),
                ):
                    self.assertEqual(exit_check, next_command)

    def test_windows_workflows_run_repo_wide_powershell_51_validation(
        self,
    ) -> None:
        compatibility_test = (
            ROOT / "scripts" / "test_windows_powershell51_compatibility.ps1"
        )
        self.assertTrue(compatibility_test.is_file())

        command = (
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
            "-File ..\\scripts\\test_windows_powershell51_compatibility.ps1"
        )
        for workflow_name in ("ci.yml", "release.yml"):
            workflow = (
                ROOT / ".github" / "workflows" / workflow_name
            ).read_text(encoding="utf-8")
            build_step = workflow.split("- name: Build Windows packages", 1)[1]
            build_step = build_step.split("\n      - name:", 1)[0]
            with self.subTest(workflow=workflow_name):
                self.assertIn("shell: powershell", build_step)
                self.assertIn(command, build_step)
                self.assertNotIn("continue-on-error", build_step)

    def test_windows_workflows_smoke_install_and_uninstall_the_built_package(
        self,
    ) -> None:
        smoke_script = ROOT / "scripts" / "test_windows_installer_package.ps1"
        self.assertTrue(smoke_script.is_file())
        smoke = smoke_script.read_text(encoding="utf-8")
        self.assertIn("$env:GITHUB_ACTIONS -ne 'true'", smoke)
        self.assertIn("Start-Process", smoke)
        self.assertIn("SSRVPN_Setup.exe", smoke)
        self.assertIn("unins000.exe", smoke)
        self.assertIn("ssrvpn_windows.exe", smoke)
        self.assertIn("bin\\ssrvpn_windows_app.exe", smoke)

        invocation = (
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
            "-File ..\\scripts\\test_windows_installer_package.ps1 "
            "-InstallerPath .\\SSRVPN_Setup.exe"
        )
        for workflow_name in ("ci.yml", "release.yml"):
            workflow = (
                ROOT / ".github" / "workflows" / workflow_name
            ).read_text(encoding="utf-8")
            build_step = workflow.split("- name: Build Windows packages", 1)[1]
            build_step = build_step.split("\n      - name:", 1)[0]
            with self.subTest(workflow=workflow_name):
                self.assertIn(invocation, build_step)
                self.assertIn(
                    "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }",
                    build_step,
                )

    def test_release_pipeline_publishes_installer_and_checksum(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        required = {
            "tool\\build_installer.ps1",
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

    def test_windows_build_tools_read_json_as_utf8_and_require_inno_65(self) -> None:
        package_script = (
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1"
        ).read_text(encoding="utf-8")
        installer_script = (
            ROOT / "SSRVPN_Windows" / "tool" / "build_installer.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "Get-Content -LiteralPath $dependenciesPath -Encoding UTF8 -Raw",
            package_script,
        )
        self.assertIn("[version]'6.5.0'", installer_script)
        self.assertIn("VersionInfo.ProductVersion", installer_script)
        self.assertIn("Inno Setup 6.5", installer_script)

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
