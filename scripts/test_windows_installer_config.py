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
        self.assertIn("CloseApplications=no", script)
        self.assertNotIn("CloseApplications=force", script)
        self.assertNotIn("CloseApplicationsFilter=", script)
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
        self.assertIn("覆盖升级会保留安装版的设置、订阅", notice)
        self.assertIn("旧独立副本不会被搜索或修改", notice)
        self.assertNotIn("永久删除当前 Windows 用户的 SSRVPN 旧数据", notice)
        self.assertIn("ssrvpn_windows_app.exe", script)
        self.assertIn("ssrvpn_windows.exe", script)
        self.assertNotRegex(script, r"taskkill[^\n]+mihomo\.exe")
        run_entry = next(
            line for line in script.splitlines() if line.startswith('Filename: "{app}')
        )
        self.assertIn('Description: "{cm:LaunchProgram,SSRVPN}"', run_entry)
        self.assertIn("postinstall", run_entry)
        self.assertIn("skipifsilent", run_entry)

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
        self.assertIn("else if StopResult = 3 then", prepare)
        self.assertIn(
            "无法确认 SSRVPN 进程归属或安全恢复系统代理，安装尚未修改程序文件",
            prepare,
        )
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

    def test_installer_holds_app_and_launcher_gates_only_during_file_changes(
        self,
    ) -> None:
        installer = (
            ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "AppInstanceMutexName = 'Local\\SSRVPN_Windows_SingleInstance'",
            installer,
        )
        self.assertIn(
            "LauncherMutexName = 'Local\\SSRVPN_Windows_Launcher'", installer
        )
        for api in (
            "CreateMutexW@kernel32.dll stdcall",
            "OpenMutexW@kernel32.dll stdcall",
            "WaitForSingleObject@kernel32.dll stdcall",
            "ReleaseMutex@kernel32.dll stdcall",
            "CloseHandle@kernel32.dll stdcall",
        ):
            with self.subTest(api=api):
                self.assertIn(api, installer)
        self.assertIn(
            "function WinCreateMutex(Attributes: Cardinal;", installer
        )
        self.assertIn(
            "function WinOpenMutex(DesiredAccess: Cardinal;", installer
        )
        self.assertNotIn("NativeUInt", installer)

        create_or_open = installer.split(
            "function CreateOrOpenGateMutex(Name: String): THandle;", 1
        )[1].split("function HoldInstallGateHandles", 1)[0]
        self.assertLess(
            create_or_open.index("WinCreateMutex(0, False, Name)"),
            create_or_open.index("if Result = 0 then"),
        )
        self.assertLess(
            create_or_open.index("if Result = 0 then"),
            create_or_open.index(
                "WinOpenMutex(SynchronizeAccess, False, Name)"
            ),
        )
        hold_gates = installer.split(
            "function HoldInstallGateHandles: Boolean;", 1
        )[1].split("function AcquireLauncherGate", 1)[0]
        self.assertEqual(hold_gates.count("CreateOrOpenGateMutex("), 2)
        self.assertNotIn("WinCreateMutex(", hold_gates)

        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1].split("procedure CurStepChanged", 1)[0]
        self.assertLess(
            prepare.index("HoldInstallGateHandles"),
            prepare.index("if UpdateHandoffDetected then"),
        )
        handoff = prepare.split("if UpdateHandoffDetected then", 1)[1].split(
            "else\n  begin\n    StopResult := StopSsrvpnProcesses", 1
        )[0]
        self.assertLess(
            handoff.index("'ready:' + UpdateHandoffToken"),
            handoff.index("AcquireLauncherGate(UpdateHandoffWaitMilliseconds)"),
        )
        self.assertLess(
            handoff.index("AcquireLauncherGate(UpdateHandoffWaitMilliseconds)"),
            handoff.index("StopResult := StopSsrvpnProcesses"),
        )
        normal = prepare[
            prepare.index("else\n  begin\n    StopResult := StopSsrvpnProcesses") :
        ]
        self.assertLess(
            normal.index("StopResult := StopSsrvpnProcesses"),
            normal.index("AcquireLauncherGate(GateWaitMilliseconds)"),
        )
        self.assertIn("ReleaseInstallGates", prepare)

        cur_step = installer.split("procedure CurStepChanged", 1)[1].split(
            "procedure DeinitializeSetup", 1
        )[0]
        self.assertIn("CurStep = ssPostInstall", cur_step)
        self.assertIn("ReleaseInstallGates", cur_step)
        deinitialize = installer.split("procedure DeinitializeSetup;", 1)[1].split(
            "function InitializeUninstall", 1
        )[0]
        self.assertIn("ReleaseInstallGates", deinitialize)

        uninstall = installer.split("function InitializeUninstall(): Boolean;", 1)[1]
        self.assertLess(
            uninstall.index("HoldInstallGateHandles"),
            uninstall.index("StopResult := RunStopSsrvpnProcesses"),
        )
        self.assertLess(
            uninstall.index("StopResult := RunStopSsrvpnProcesses"),
            uninstall.index("AcquireLauncherGate"),
        )
        self.assertIn(
            "procedure DeinitializeUninstall;\nbegin\n  ReleaseInstallGates;",
            installer,
        )
        self.assertIn("nowait postinstall skipifsilent", installer)

    def test_verified_update_handoff_waits_for_elevated_launcher_exit(self) -> None:
        installer = (
            ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss"
        ).read_text(encoding="utf-8")

        initialize = installer.split("function InitializeSetup(): Boolean;", 1)[
            1
        ].split("procedure ReleaseInstallGates", 1)[0]
        self.assertIn("LoadStringFromFile(RequestPath, Token)", initialize)
        self.assertIn("IsValidUpdateHandoffToken(Token)", initialize)
        self.assertIn("OpenEventW@kernel32.dll stdcall", installer)
        self.assertLess(
            initialize.index("HandoffEvent := WinOpenEvent"),
            initialize.index("UpdateHandoffDetected := True"),
        )
        self.assertIn("Length(Token) = 32", installer)
        self.assertIn("UpdateHandoffEventPrefix + String(Token)", initialize)

        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1].split("procedure CurStepChanged", 1)[0]
        handoff = prepare.split("if UpdateHandoffDetected then", 1)[1].split(
            "else\n  begin\n    StopResult := StopSsrvpnProcesses", 1
        )[0]
        self.assertLess(
            handoff.index("IsUpdateHandoffLive"),
            handoff.index("SaveStringToFile"),
        )
        self.assertLess(
            handoff.index("SaveStringToFile"),
            handoff.index("AcquireLauncherGate(UpdateHandoffWaitMilliseconds)"),
        )
        self.assertLess(
            handoff.index("AcquireLauncherGate(UpdateHandoffWaitMilliseconds)"),
            handoff.index("StopResult := StopSsrvpnProcesses"),
        )
        self.assertIn("'ready:' + UpdateHandoffToken", handoff)
        self.assertIn("更新安装器交接已过期，安装尚未修改程序文件", handoff)
        self.assertIn("等待 SSRVPN 安全退出超时，安装尚未修改程序文件", handoff)

        deinitialize = installer.split("procedure DeinitializeSetup;", 1)[1].split(
            "function InitializeUninstall", 1
        )[0]
        self.assertIn("UpdateHandoffDetected and (not UpdateHandoffReady)", deinitialize)
        self.assertIn("'cancelled:' + UpdateHandoffToken", deinitialize)

    def test_installer_preserves_user_state_and_replaces_only_program_files(
        self,
    ) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")

        self.assertIn("[InstallDelete]", installer)
        self.assertLess(installer.index("[InstallDelete]"), installer.index("[Files]"))
        install_delete = installer.split("[InstallDelete]", 1)[1].split(
            "[UninstallDelete]", 1
        )[0]
        self.assertIn('Type: files; Name: "{app}\\*"', install_delete)
        self.assertIn('Type: files; Name: "{app}\\bin\\*"', install_delete)
        self.assertIn(
            'Type: filesandordirs; Name: "{app}\\bin\\data"', install_delete
        )
        self.assertIn(
            'Type: filesandordirs; Name: "{app}\\installer"', install_delete
        )
        self.assertNotIn('Type: filesandordirs; Name: "{app}\\*"', install_delete)
        self.assertNotIn('Name: "{app}\\bin\\ssrvpn"', install_delete)
        self.assertNotIn(
            'Name: "{localappdata}\\SSRVPN\\ssrvpn"', install_delete
        )
        self.assertNotIn(
            'Name: "{localappdata}\\SSRVPN\\window_state.json"', install_delete
        )
        self.assertNotIn(
            'Name: "{localappdata}\\SSRVPN\\installer-recovery"',
            install_delete,
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
        for cache_path in (
            r"{userappdata}\SSRVPN.exe\EBWebView",
            r"{localappdata}\vip.ssrvpn.windows\EBWebView",
        ):
            with self.subTest(cache_path=cache_path):
                cleanup_entry = (
                    f'Type: filesandordirs; Name: "{cache_path}"'
                )
                self.assertIn(cleanup_entry, installer.split("[UninstallDelete]", 1)[0])
                self.assertIn(
                    cleanup_entry,
                    installer.split("[UninstallDelete]", 1)[1].split("[Files]", 1)[0],
                )
        uninstall_cleanup = [
            line
            for line in installer.split("[UninstallDelete]", 1)[1]
            .split("[Files]", 1)[0]
            .splitlines()
            if line.startswith("Type:")
        ]
        self.assertEqual(2, len(uninstall_cleanup))
        self.assertFalse((installer_root / "prepare_install_directory.ps1").exists())
        self.assertNotIn("prepare_install_directory.ps1", installer)
        self.assertNotIn("InstallDataRestore", installer)
        self.assertNotIn("RestoreInstallData", installer)

    def test_program_file_transaction_wraps_destructive_overwrite(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        helper_path = installer_root / "program_files_transaction.ps1"
        self.assertTrue(helper_path.is_file())
        helper = helper_path.read_text(encoding="utf-8")
        build_installer = (
            ROOT / "SSRVPN_Windows" / "tool" / "build_installer.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'Source: "{#ProjectDir}\\installer\\program_files_transaction.ps1"; '
            "Flags: dontcopy",
            installer,
        )
        self.assertIn(
            'Source: "{#ProjectDir}\\installer\\program_files_transaction.ps1"; '
            'DestDir: "{app}\\installer"; Flags: ignoreversion',
            installer,
        )
        self.assertIn("#ifndef PayloadManifestPath", installer)
        self.assertIn("CloseApplications=no", installer)
        self.assertNotIn("CloseApplicationsFilter=", installer)
        self.assertIn(
            'Source: "{#PayloadManifestPath}"; '
            'DestName: "ssrvpn_expected_payload.sha256"; Flags: dontcopy',
            installer,
        )
        payload_source = next(
            line
            for line in installer.splitlines()
            if line.startswith('Source: "{#SourceDir}\\*"')
        )
        self.assertIn(r'Excludes: "bin\ssrvpn,bin\ssrvpn\*"', payload_source)
        files_section = installer.split("[Files]", 1)[1].split("[Icons]", 1)[0]
        self.assertIn("dontcopy noencryption", files_section)
        self.assertLess(
            files_section.index("ssrvpn_expected_payload.sha256"),
            files_section.index('Source: "{#SourceDir}\\*"'),
        )
        self.assertIn("/DPayloadManifestPath=$payloadManifestPath", build_installer)
        self.assertIn("Get-FileHash", build_installer)
        self.assertIn(
            "Installer payload must not contain user-owned data", build_installer
        )
        for installed_helper in (
            "stop_ssrvpn_processes.ps1",
            "proxy_transaction_state.ps1",
            "tun_ownership.ps1",
            "program_files_transaction.ps1",
        ):
            self.assertIn(installed_helper, build_installer)
        self.assertIn("ProgramFilesRecoveryPending := DirExists(", installer)
        begin_transaction = installer.split(
            "function BeginProgramFilesTransaction: Boolean;", 1
        )[1].split("function CommitProgramFilesTransaction", 1)[0]
        self.assertNotIn(
            "LastProgramFilesTransactionStatus = 'PREPARED'",
            begin_transaction,
        )
        commit_transaction = installer.split(
            "function CommitProgramFilesTransaction: Boolean;", 1
        )[1].split("function PrepareToInstall", 1)[0]
        self.assertNotIn(
            "LastProgramFilesTransactionStatus = 'COMMITTED'",
            commit_transaction,
        )
        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1].split("procedure CurStepChanged", 1)[0]
        success = prepare.split("if StopResult = 0 then", 1)[1].split(
            "else if StopResult = 3 then", 1
        )[0]
        self.assertLess(
            success.index("RecoverPendingProgramFilesTransaction"),
            success.index("BeginProgramFilesTransaction"),
        )
        self.assertIn("ReleaseInstallGates", success)
        recover_transaction = installer.split(
            "function RecoverPendingProgramFilesTransaction: Boolean;", 1
        )[1].split("function BeginProgramFilesTransaction", 1)[0]
        self.assertIn(
            "ProgramFilesTransactionPrepared := ProgramFilesRecoveryPending",
            recover_transaction,
        )

        cur_step = installer.split("procedure CurStepChanged", 1)[1].split(
            "procedure DeinitializeSetup", 1
        )[0]
        self.assertIn("RaiseException(", cur_step)
        self.assertLess(
            cur_step.index("CommitProgramFilesTransaction"),
            cur_step.index("ReleaseInstallGates"),
        )
        self.assertNotIn("InstalledProgramFilesComplete", installer)
        deinitialize = installer.split("procedure DeinitializeSetup;", 1)[1].split(
            "function InitializeUninstall", 1
        )[0]
        self.assertLess(
            deinitialize.index("RecoverPendingProgramFilesTransaction"),
            deinitialize.index("ReleaseInstallGates"),
        )

        self.assertIn(
            "ValidateSet('Begin', 'Recover', 'Clear', 'Validate', "
            "'Commit', 'Discard')",
            helper,
        )
        self.assertIn("ExpectedPayloadManifestPath", helper)
        self.assertIn("UninstallRegistrySubkey", helper)
        self.assertIn("$preservedDataRelativePath = 'bin\\ssrvpn'", helper)
        self.assertIn("function Begin-ProgramFilesTransaction", helper)
        self.assertIn("function Recover-ProgramFilesTransaction", helper)
        self.assertIn("function Clear-ProgramFilesForInstall", helper)
        self.assertIn("function Validate-ProgramFilesTransaction", helper)
        self.assertIn("function Commit-ProgramFilesTransaction", helper)
        self.assertIn("function Discard-ProgramFilesTransaction", helper)
        self.assertIn("function Read-ExpectedPayloadManifest", helper)
        self.assertIn("function Test-InstalledPayload", helper)
        self.assertIn("function New-UninstallRegistrySnapshot", helper)
        self.assertIn("function Read-UninstallRegistrySnapshot", helper)
        self.assertIn("function Restore-UninstallRegistrySnapshot", helper)
        self.assertIn("uninstall-registry.json", helper)
        self.assertIn("CURRENT_ALREADY_VERIFIED", helper)
        self.assertIn("phase = 'prepared'", helper)
        self.assertIn("'cleared'", helper)
        self.assertIn("'validated'", helper)
        self.assertIn("'committed'", helper)
        self.assertIn("'restored'", helper)
        self.assertIn(".cleanup.", helper)
        self.assertNotIn(
            "if ($null -eq $installItem) { return 'NO_PROGRAM_FILES' }",
            helper,
        )
        self.assertIn("function Remove-CommittedTransaction", helper)
        self.assertNotIn(
            "Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue",
            helper,
        )
        self.assertNotIn(
            "Copy-Item -LiteralPath $installDir -Destination $backupProgramRoot "
            "-Recurse",
            helper,
        )

        validate_callback = installer.split(
            "procedure ValidateProgramFilesTransaction;", 1
        )[1].split("function PrepareToInstall", 1)[0]
        self.assertRegex(
            validate_callback,
            re.compile(
                r"RunProgramFilesTransaction\(\s*'Validate', "
                r"'ssrvpn_expected_payload\.sha256'\)"
            ),
        )
        self.assertIn("RaiseException(", validate_callback)
        installed_transaction_helper = next(
            line
            for line in files_section.splitlines()
            if 'DestDir: "{app}\\installer"' in line
            and "program_files_transaction.ps1" in line
        )
        self.assertIn(
            "AfterInstall: ValidateProgramFilesTransaction",
            installed_transaction_helper,
        )
        commit_helper = helper.split(
            "function Commit-ProgramFilesTransaction", 1
        )[1].split("function Discard-ProgramFilesTransaction", 1)[0]
        self.assertNotIn("Test-InstalledPayload", commit_helper)
        self.assertIn("phase -cne 'validated'", commit_helper)
        self.assertIn(
            "[System.StringComparison]::OrdinalIgnoreCase", helper
        )
        self.assertIn(" -UninstallRegistrySubkey ", installer)
        self.assertIn(" -DesktopShortcutPath ", installer)
        self.assertIn(" -StartMenuShortcutPath ", installer)
        self.assertLess(
            success.index("BeginProgramFilesTransaction"),
            success.index("ClearProgramFilesForInstall"),
        )

        initialize_uninstall = installer.split(
            "function InitializeUninstall(): Boolean;", 1
        )[1].split("procedure CurUninstallStepChanged", 1)[0]
        self.assertIn(
            "RunInstalledProgramFilesTransaction('Discard')", initialize_uninstall
        )
        self.assertLess(
            initialize_uninstall.index("AcquireLauncherGate"),
            initialize_uninstall.index(
                "RunInstalledProgramFilesTransaction('Discard')"
            ),
        )

    def test_program_file_transaction_bounds_untrusted_recovery_inputs(
        self,
    ) -> None:
        helper = (
            ROOT
            / "SSRVPN_Windows"
            / "installer"
            / "program_files_transaction.ps1"
        ).read_text(encoding="utf-8")

        # Keep every resource ceiling together so packaging and recovery reviews
        # cannot silently harden one path while leaving another unbounded.
        for declaration in (
            "$maxMetadataDocumentBytes = 8MB",
            "$maxProgramRelativePathChars = 1024",
            "$maxProgramRelativePathDepth = 64",
            "$maxProgramDirectoryCount = 50000",
            "$maxProgramFileCount = 50000",
            "$maxProgramFileBytes = 2GB",
            "$maxProgramTotalBytes = 8GB",
        ):
            self.assertIn(declaration, helper)

        self.assertIn("function Read-BoundedJsonDocument", helper)
        self.assertIn("function Assert-ExactObjectSchema", helper)
        self.assertIn("function Assert-BoundedProgramRelativePath", helper)
        self.assertIn("function Get-BoundedFileMetadata", helper)

        state_reader = helper.split("function Read-TransactionState", 1)[1].split(
            "function Read-Manifest", 1
        )[0]
        self.assertIn("Read-BoundedJsonDocument", state_reader)
        self.assertIn("Assert-ExactObjectSchema", state_reader)
        self.assertIn("$state.schemaVersion -isnot [int]", state_reader)
        self.assertIn("$state.phase -isnot [string]", state_reader)

        manifest_reader = helper.split("function Read-Manifest", 1)[1].split(
            "function Read-ExpectedPayloadManifest", 1
        )[0]
        self.assertIn("Read-BoundedJsonDocument", manifest_reader)
        self.assertGreaterEqual(manifest_reader.count("Assert-ExactObjectSchema"), 2)
        self.assertIn("$files.Count -gt $script:maxProgramFileCount", manifest_reader)
        self.assertIn("$entry.length -isnot [long]", manifest_reader)
        self.assertIn("Assert-BoundedProgramRelativePath", manifest_reader)
        self.assertIn("$script:maxProgramTotalBytes", manifest_reader)

        inventory = helper.split("function Add-InventoryEntry", 1)[1].split(
            "function Get-ProgramInventory", 1
        )[0]
        self.assertIn("Assert-BoundedProgramRelativePath", inventory)
        self.assertIn("$Limits.directoryCount", inventory)
        self.assertIn("$script:maxProgramDirectoryCount", inventory)
        self.assertIn("$Limits.fileCount", inventory)
        self.assertIn("$script:maxProgramFileCount", inventory)
        self.assertIn("$script:maxProgramTotalBytes", inventory)
        self.assertIn("Get-BoundedFileMetadata", inventory)

        begin = helper.split("function Begin-ProgramFilesTransaction", 1)[1].split(
            "function Recover-ProgramFilesTransaction", 1
        )[0]
        self.assertLess(
            begin.index("Get-ProgramInventory"),
            begin.index("Copy-SafeContents"),
        )

        destructive_clear = helper.split(
            "function Remove-CurrentProgramFiles", 1
        )[1].split("function Clear-StaleStagingDirectories", 1)[0]
        self.assertIn("Get-ProgramInventory", destructive_clear)
        self.assertIn("-ExcludePreservedData", destructive_clear)

        json_writer = helper.split("function ConvertTo-BoundedJsonText", 1)[1].split(
            "function Invoke-RegExe", 1
        )[0]
        self.assertIn("$script:maxMetadataDocumentBytes", json_writer)
        self.assertIn("GetByteCount", json_writer)

        expected_manifest = helper.split(
            "function Read-ExpectedPayloadManifest", 1
        )[1].split("function Test-InstalledPayload", 1)[0]
        self.assertIn("$script:maxMetadataDocumentBytes", expected_manifest)
        self.assertIn("$script:maxProgramFileCount", expected_manifest)
        self.assertIn("Assert-BoundedProgramRelativePath", expected_manifest)

        runtime = (
            ROOT / "scripts" / "test_windows_program_files_transaction.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("oversized source was copied into recovery", runtime)
        self.assertIn("oversized recovery state changed the installed program", runtime)
        self.assertIn("invalid manifest schema changed the installed program", runtime)

    def test_windows_jobs_run_program_file_transaction_fault_injection(self) -> None:
        runtime_test = (
            ROOT / "scripts" / "test_windows_program_files_transaction.ps1"
        )
        self.assertTrue(runtime_test.is_file())
        runtime = runtime_test.read_text(encoding="utf-8")
        self.assertIn("bin\\ssrvpn\\user-data.sentinel", runtime)
        self.assertIn("FileShare]::None", runtime)
        self.assertIn("-ExpectFailure", runtime)
        self.assertIn("tampered backup changed the current program", runtime)
        self.assertIn("unverified partial program file survived recovery", runtime)
        self.assertIn("successful commit changed user data", runtime)
        self.assertIn(
            "intact current program changed during failed no-op recovery", runtime
        )
        self.assertIn("payload mismatch unexpectedly committed", runtime)
        self.assertIn("missing recovery transaction unexpectedly committed", runtime)
        self.assertIn("unvalidated payload unexpectedly committed", runtime)
        self.assertIn("payload path casing unexpectedly failed validation", runtime)
        self.assertIn(
            "stale nested program file survived transactional clear", runtime
        )
        self.assertIn("old-registry-version", runtime)
        self.assertIn("new-registry-version", runtime)
        self.assertIn(
            "clean-install recovery left uninstall metadata", runtime
        )
        self.assertIn("unexpected-plugin.dll", runtime)
        self.assertIn("discard changed bin\\ssrvpn user data", runtime)
        self.assertIn("failed discard changed the installed launcher", runtime)
        package_smoke = (
            ROOT / "scripts" / "test_windows_installer_package.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("New-PendingProgramFileTransaction", package_smoke)
        self.assertIn(
            "SSRVPN uninstall left old program recovery binaries behind",
            package_smoke,
        )

        invocation = (
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
            "-File ..\\scripts\\test_windows_program_files_transaction.ps1"
        )
        for workflow_name in ("ci.yml", "release.yml"):
            workflow = (
                ROOT / ".github" / "workflows" / workflow_name
            ).read_text(encoding="utf-8")
            build_step = workflow.split("- name: Build Windows installer", 1)[1]
            build_step = build_step.split("\n      - name:", 1)[0]
            with self.subTest(workflow=workflow_name):
                self.assertIn(invocation, build_step)
                self.assertLess(
                    build_step.index(invocation),
                    build_step.index("tool\\package_windows.ps1"),
                )

    def test_windows_package_rejects_user_owned_payload_trees(self) -> None:
        package_script = (
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1"
        ).read_text(encoding="utf-8")
        guard_path = (
            ROOT
            / "SSRVPN_Windows"
            / "tool"
            / "assert_clean_package_payload.ps1"
        )
        runtime_path = ROOT / "scripts" / "test_windows_package_payload_guard.ps1"

        self.assertTrue(guard_path.is_file())
        guard = guard_path.read_text(encoding="utf-8")
        self.assertIn("Installer payload must not contain user-owned data", guard)
        self.assertIn("@('ssrvpn', 'bin\\ssrvpn')", guard)
        self.assertGreaterEqual(
            package_script.count("assert_clean_package_payload.ps1"), 1
        )
        self.assertIn("Assert-CleanPackagePayload -Root $buildDir", package_script)
        self.assertIn("Assert-CleanPackagePayload -Root $Root", package_script)

        self.assertTrue(runtime_path.is_file())
        runtime = runtime_path.read_text(encoding="utf-8")
        self.assertIn("root-user-data", runtime)
        self.assertIn("nested-user-data", runtime)
        self.assertIn("-ExpectFailure", runtime)

        invocation = (
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
            "-File ..\\scripts\\test_windows_package_payload_guard.ps1"
        )
        for workflow_name in ("ci.yml", "release.yml"):
            workflow = (
                ROOT / ".github" / "workflows" / workflow_name
            ).read_text(encoding="utf-8")
            build_step = workflow.split("- name: Build Windows installer", 1)[1]
            build_step = build_step.split("\n      - name:", 1)[0]
            with self.subTest(workflow=workflow_name):
                self.assertIn(invocation, build_step)
                self.assertLess(
                    build_step.index(invocation),
                    build_step.index("tool\\package_windows.ps1"),
                )

    def test_installer_cleanup_is_path_exact_and_best_effort(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        stopper = (installer_root / "stop_ssrvpn_processes.ps1").read_text(
            encoding="utf-8"
        )
        tun_helper = (installer_root / "tun_ownership.ps1").read_text(
            encoding="utf-8"
        )
        transaction_state = (
            installer_root / "proxy_transaction_state.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn("stop_ssrvpn_processes.ps1", installer)
        self.assertIn("proxy_transaction_state.ps1", installer)
        self.assertIn("tun_ownership.ps1", installer)
        self.assertIn(". $proxyTransactionStatePath", stopper)
        self.assertIn(". $tunOwnershipPath", stopper)
        self.assertIn("function Get-SsrvpnTunOwnership", tun_helper)
        self.assertIn("StopResult := StopSsrvpnProcesses", installer)
        self.assertIn("hasProxyEnable", transaction_state)
        self.assertIn("$originalMayBeDisabled", transaction_state)
        self.assertIn(
            "$originalMayBeDisabled -and $disabledProxy",
            transaction_state,
        )
        self.assertIn("HasProxyEnable", stopper)
        self.assertIn(
            "Set-OrRemoveRegistryValue -Path $regPath -Name ProxyEnable",
            stopper,
        )
        self.assertIn("if StopResult = 0 then", installer)
        lock_acquire = stopper.index(
            "$script:ProxyTransactionLockStream = Enter-ProxyTransactionLock"
        )
        instance_gate = stopper.index(
            "$script:AppInstanceMutex = New-Object System.Threading.Mutex"
        )
        self.assertLess(lock_acquire, stopper.index("$currentSessionId ="))
        self.assertLess(lock_acquire, instance_gate)
        self.assertLess(instance_gate, stopper.index("$currentSessionId ="))
        self.assertLess(lock_acquire, stopper.index("$apps = @()"))
        self.assertLess(lock_acquire, stopper.index("$proxyBackup = Get-ProxyRecoveryState"))
        lock_function = stopper.split("function Enter-ProxyTransactionLock", 1)[1]
        lock_function = lock_function.split(
            "$script:ProxyTransactionLockStream = $null", 1
        )[0]
        self.assertIn("system_proxy_transaction.lock", lock_function)
        self.assertIn("[System.IO.FileMode]::OpenOrCreate", lock_function)
        self.assertIn("[System.IO.FileAccess]::ReadWrite", lock_function)
        self.assertIn("[System.IO.FileShare]::ReadWrite", lock_function)
        self.assertIn("[System.IO.FileShare]::Delete", lock_function)
        self.assertIn("$stream.Lock(0, 1)", lock_function)
        self.assertIn("AddMilliseconds($TimeoutMilliseconds)", lock_function)
        self.assertIn("Start-Sleep -Milliseconds 100", lock_function)
        self.assertIn(
            "$ProxyTransactionLockTimeoutMilliseconds = 10000", stopper
        )
        lock_failure = stopper[lock_acquire:stopper.index("$currentSessionId =")]
        self.assertIn("exit 3", lock_failure)
        self.assertIn("Local\\SSRVPN_Windows_SingleInstance", lock_failure)
        proxy_service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" /
            "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        native_recovery = (
            ROOT / "SSRVPN_Windows" / "windows" / "runner" /
            "system_proxy_recovery.cpp"
        ).read_text(encoding="utf-8")
        self.assertIn("system_proxy_transaction.lock", proxy_service)
        self.assertIn('L"system_proxy_transaction.lock"', native_recovery)
        self.assertNotIn("taskkill", stopper.lower())
        for stale_pid_termination in (
            "Stop-Process -Id $app.ProcessId",
            "Stop-Process -Id $launcher.ProcessId",
            "Stop-Process -Id $core.ProcessId",
        ):
            self.assertNotIn(stale_pid_termination, stopper)
        self.assertIn("SsrvpnVerifiedProcessTerminator", stopper)
        self.assertIn(
            "ProcessQueryLimitedInformation | ProcessTerminate | Synchronize",
            stopper,
        )
        verified_termination = stopper.split(
            "public static int Terminate(", 1
        )[1].split("\n  }\n}\n'@", 1)[0]
        for api in (
            "OpenProcess(",
            "GetProcessId(process)",
            "ProcessIdToSessionId(liveProcessId",
            "QueryFullProcessImageNameW(",
            "GetProcessTimes(",
            "TerminateProcess(process, 1)",
            "WaitForSingleObject(process, 8000)",
        ):
            self.assertIn(api, verified_termination)
        self.assertIn(
            "ulong expectedCreationTimeUtcFileTime", verified_termination
        )
        self.assertIn(
            "liveCreationTimeUtcFileTime != expectedCreationTimeUtcFileTime",
            verified_termination,
        )
        self.assertIn(
            "if (!GetExitCodeProcess(process, out exitCode))",
            verified_termination,
        )
        self.assertNotIn(
            "if (GetExitCodeProcess(process, out exitCode) &&",
            verified_termination,
        )
        self.assertLess(
            verified_termination.index(
                "if (!GetExitCodeProcess(process, out exitCode))"
            ),
            verified_termination.index("exitCode != StillActive"),
        )
        self.assertEqual(1, verified_termination.count("OpenProcess("))
        self.assertLess(
            verified_termination.index("OpenProcess("),
            verified_termination.index("GetProcessId(process)"),
        )
        self.assertLess(
            verified_termination.index("GetProcessId(process)"),
            verified_termination.index("QueryFullProcessImageNameW("),
        )
        self.assertLess(
            verified_termination.index("QueryFullProcessImageNameW("),
            verified_termination.index("GetProcessTimes("),
        )
        self.assertLess(
            verified_termination.index("GetProcessTimes("),
            verified_termination.index(
                "liveCreationTimeUtcFileTime != expectedCreationTimeUtcFileTime"
            ),
        )
        self.assertLess(
            verified_termination.index(
                "liveCreationTimeUtcFileTime != expectedCreationTimeUtcFileTime"
            ),
            verified_termination.index("TerminateProcess(process, 1)"),
        )
        self.assertLess(
            verified_termination.index("TerminateProcess(process, 1)"),
            verified_termination.index("WaitForSingleObject(process, 8000)"),
        )
        self.assertLess(
            verified_termination.index("WaitForSingleObject(process, 8000)"),
            verified_termination.index("CloseHandle(process)"),
        )
        self.assertIn("WaitTimeout", verified_termination)
        self.assertIn("TimeoutException", verified_termination)
        self.assertIn("ExecutablePath", stopper)
        self.assertIn("SessionId", stopper)
        self.assertIn("CreationTimeUtcFileTime", stopper)
        self.assertIn("remainingApps", stopper)
        self.assertIn("remainingCores", stopper)
        self.assertIn("exit 2", stopper)
        self.assertIn("Restore-OwnedSystemProxy", stopper)
        runtime_flow = stopper.split("$proxyBackup = Get-ProxyRecoveryState", 1)[1]
        self.assertLess(
            runtime_flow.index(
                "Stop-VerifiedProcess -ProcessId ([int]$app.ProcessId)"
            ),
            runtime_flow.index("try {\n  Restore-OwnedSystemProxy"),
        )
        self.assertLess(
            runtime_flow.index("$appsBeforeRecovery = @("),
            runtime_flow.index("try {\n  Restore-OwnedSystemProxy"),
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
        self.assertIn("$autoDetectDisabled", invalid_repair)
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
        process_lookup = stopper.split("function Get-ProcessesByName", 1)[1]
        process_lookup = process_lookup.split("function Test-ExactPath", 1)[0]
        self.assertNotIn("ErrorAction SilentlyContinue", process_lookup)
        self.assertIn("Get-Process -ErrorAction Stop", process_lookup)
        self.assertIn("Executable path is unavailable", process_lookup)
        self.assertIn("Get-Process -Id $processId -ErrorAction Stop", process_lookup)
        self.assertIn("Process identity changed while verifying PID", process_lookup)
        self.assertIn("$live.ProcessName -ine $expectedProcessName", process_lookup)
        self.assertIn("$live.SessionId -ne $currentSessionId", process_lookup)
        self.assertIn("$candidateSessionId -ne $currentSessionId) { continue }", process_lookup)
        fallback_session_filter = process_lookup.index(
            "$_.SessionId -eq $currentSessionId"
        )
        fallback_path_read = process_lookup.index("$executablePath = $_.Path")
        self.assertLess(fallback_session_filter, fallback_path_read)
        candidate_session_check = process_lookup.index(
            "$candidateSessionId -ne $currentSessionId"
        )
        candidate_path_check = process_lookup.index(
            "if (-not $candidate.ExecutablePath)"
        )
        self.assertLess(candidate_session_check, candidate_path_check)
        remove_state = stopper.split("function Remove-ProxyRecoveryState", 1)[1]
        remove_state = remove_state.split("function Test-RequiredProperties", 1)[0]
        self.assertIn("$nativeExists = Test-Path -Path $nativePath", remove_state)
        self.assertIn(
            "if (Test-Path -LiteralPath $jsonPath -PathType Leaf)",
            remove_state,
        )
        self.assertNotIn("ErrorAction SilentlyContinue", remove_state)
        self.assertIn("$json._activationInProgress = $false", remove_state)
        self.assertIn("-Name 'Valid' -Type DWord -Value 0", remove_state)
        for terminal_flag in (
            "ActivationInProgress",
            "RestoreInProgress",
            "EndpointRestoreInProgress",
        ):
            self.assertIn(f"@{{ Name = '{terminal_flag}'; Value = 0 }}", remove_state)
        self.assertIn("$flagsTerminal = $true", remove_state)
        self.assertIn("if ($flagsTerminal) { $nativeTerminal = $true }", remove_state)
        json_terminal = remove_state.index("$json._activationInProgress = $false")
        json_gate = remove_state.index("if (-not $jsonTerminal)")
        invalidate = remove_state.index("-Name 'Valid' -Type DWord -Value 0")
        native_delete = remove_state.index(
            "Remove-Item -Path $nativePath -Recurse -Force"
        )
        native_gate = remove_state.index("if (-not $nativeTerminal)")
        json_delete = remove_state.rindex(
            "Remove-Item -LiteralPath $jsonPath -Force"
        )
        runonce_delete = remove_state.rindex("Remove-ProxyRecoveryRunOnce")
        self.assertLess(json_terminal, json_gate)
        self.assertLess(json_gate, invalidate)
        self.assertLess(invalidate, native_delete)
        self.assertLess(native_delete, native_gate)
        self.assertLess(native_gate, json_delete)
        self.assertLess(json_delete, runonce_delete)
        self.assertIn("$cleanupErrors +=", remove_state)
        self.assertIn("throw ($cleanupErrors -join '; ')", remove_state)
        set_or_remove = transaction_state.split(
            "function Set-OrRemoveRegistryValue", 1
        )[1].split("function Get-SystemProxyState", 1)[0]
        self.assertIn("$current.PSObject.Properties[$Name]", set_or_remove)
        self.assertNotIn("ErrorAction SilentlyContinue", set_or_remove)
        self.assertIn("function Test-SystemProxySafeToStop", stopper)
        safe_to_stop = stopper.split("function Test-SystemProxySafeToStop", 1)[1]
        safe_to_stop = safe_to_stop.split("$apps = @()", 1)[0]
        self.assertIn(
            "if ($null -eq $current.PSObject.Properties['ProxyEnable']) {\n"
            "      return $true",
            safe_to_stop,
        )
        self.assertIn("ProxyEnable -ne 1) { return $false }", safe_to_stop)
        self.assertIn("if (-not $hasProxyServer) { return $false }", safe_to_stop)
        self.assertGreaterEqual(stopper.count("$autoDetectDisabled"), 6)
        proxy_gate = runtime_flow.index(
            "if (-not (Test-SystemProxySafeToStop -Backup $proxyBackup"
        )
        self.assertLess(
            runtime_flow.index("foreach ($app in $installedApps)"), proxy_gate
        )
        restore_attempt = runtime_flow[
            runtime_flow.index("try {\n  Restore-OwnedSystemProxy"):proxy_gate
        ]
        self.assertLess(
            restore_attempt.index("$proxyRecoveryFailed = $true"),
            restore_attempt.index("Disable-OwnedSystemProxyEndpoint"),
        )
        self.assertIn("Test-SystemProxySafeToStop -Backup $proxyBackup", stopper)
        fallback = runtime_flow.index(
            "Disable-OwnedSystemProxyEndpoint -Backup $proxyBackup",
            proxy_gate,
        )
        final_proxy_gate = runtime_flow.index(
            "if (-not (Test-SystemProxySafeToStop -Backup $proxyBackup",
            fallback,
        )
        self.assertLess(proxy_gate, fallback)
        self.assertLess(fallback, final_proxy_gate)
        self.assertGreater(
            runtime_flow.rindex("if ($proxyRecoveryFailed)"),
            runtime_flow.index("$remainingApps = @("),
        )
        self.assertIn("$installedApps.Count -gt 0", stopper)
        self.assertIn("$installedLaunchers.Count -gt 0", stopper)
        self.assertIn("$installedCoresBefore.Count -gt 0", stopper)
        self.assertIn("[bool]$InstalledProcessRunning", stopper)
        self.assertIn(
            "-not $Backup -and $InstalledProcessRunning -and\n"
            "        (Test-OwnedProxyServer -Value $proxyServer)",
            stopper,
        )
        enumeration = stopper.index("$apps = @()")
        self.assertLess(enumeration, stopper.index("$proxyBackup = Get-ProxyRecoveryState"))
        expected_path_gate = stopper.index(
            "$InstalledAppPath = Get-ValidatedExpectedPath"
        )
        foreign_gate = stopper.index("if ($foreignApps.Count -gt 0")
        proxy_state_read = stopper.index("$proxyBackup = Get-ProxyRecoveryState")
        self.assertLess(expected_path_gate, enumeration + stopper[enumeration:].index(
            "$apps = @(Get-ProcessesByName"
        ))
        self.assertLess(foreign_gate, proxy_state_read)
        self.assertLess(foreign_gate, stopper.index("foreach ($app in $installedApps)"))
        self.assertIn("$foreignLaunchers.Count -gt 0", stopper[foreign_gate:proxy_state_read])
        self.assertIn("$foreignCores.Count -gt 0", stopper[foreign_gate:proxy_state_read])
        self.assertIn("exit 3", stopper[foreign_gate:proxy_state_read])
        self.assertIn("[string]::IsNullOrWhiteSpace($Path)", stopper)
        self.assertIn("[System.IO.Path]::IsPathRooted($Path)", stopper)
        self.assertIn(
            "Installed executable paths do not describe one SSRVPN installation",
            stopper,
        )
        self.assertNotIn("function Test-LiveProcessIdentity", stopper)
        self.assertIn("function Stop-VerifiedProcess", stopper)
        self.assertIn("$proxyServer -eq [string]$Backup.ownedProxyServer", stopper)
        self.assertIn("$ownedFingerprint", stopper)
        self.assertIn("exit 3", stopper[proxy_gate:])
        self.assertIn("$Value -isnot [int32]", stopper)
        self.assertIn("$Value -isnot [uint32]", stopper)
        self.assertGreaterEqual(
            stopper.count("Test-DwordFlag -Value $current.ProxyEnable"),
            4,
        )
        proxy_service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" /
            "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        self.assertIn("GetValueKind('ProxyEnable')", proxy_service)
        self.assertIn("GetValueKind('AutoDetect')", proxy_service)
        self.assertIn("[Microsoft.Win32.RegistryValueKind]::DWord", proxy_service)
        self.assertIn(
            "Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledAppPath",
            stopper,
        )
        self.assertIn(
            "Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledLauncherPath",
            stopper,
        )
        self.assertIn("Test-ExactPath", stopper)
        self.assertIn(
            "Stop-VerifiedProcess -ProcessId ([int]$core.ProcessId)",
            stopper,
        )
        runtime_test = (
            ROOT / "scripts" / "test_windows_installer_runtime.ps1"
        ).read_text(encoding="utf-8")
        self.assertNotIn("prepare_install_directory.ps1", runtime_test)
        self.assertIn("Foreign-instance ownership gate returned", runtime_test)
        self.assertIn("expected 3", runtime_test)
        self.assertIn("stopped a portable process", runtime_test)
        self.assertIn("modified installed runtime files", runtime_test)
        self.assertIn("Verified installer cleanup returned", runtime_test)
        self.assertIn("$heldTransactionLock.Lock(0, 1)", runtime_test)
        self.assertIn(
            "'-ProxyTransactionLockTimeoutMilliseconds', 500", runtime_test
        )
        self.assertIn("Contended proxy transaction lock returned", runtime_test)
        self.assertIn("$heldTransactionLock.Unlock(0, 1)", runtime_test)
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

    def test_installer_cleanup_status_is_fixed_and_sanitized(self) -> None:
        installer_root = ROOT / "SSRVPN_Windows" / "installer"
        installer = (installer_root / "SSRVPN.iss").read_text(encoding="utf-8")
        stopper = (installer_root / "stop_ssrvpn_processes.ps1").read_text(
            encoding="utf-8"
        )
        tun_helper = (installer_root / "tun_ownership.ps1").read_text(
            encoding="utf-8"
        )
        allowed = {
            "OK",
            "LOCK_BUSY",
            "LOCK_FAILED",
            "INSTANCE_GATE_FAILED",
            "IDENTITY_UNVERIFIED",
            "FOREIGN_INSTANCE",
            "APP_STILL_RUNNING",
            "PROXY_UNSAFE",
            "PROCESSES_STILL_RUNNING",
            "TUN_TEARDOWN_PENDING",
            "RECOVERY_CLEANUP_PENDING",
            "INTERNAL_ERROR",
        }

        self.assertIn("[string]$StatusPath = ''", stopper)
        writer = stopper.split("function Set-StopStatus", 1)[1].split(
            "Set-StopStatus -Status 'INTERNAL_ERROR'", 1
        )[0]
        self.assertIn("$script:StopStatusValues -cnotcontains $Status", writer)
        self.assertIn("[System.IO.File]::WriteAllText(", writer)
        self.assertIn("[System.Text.Encoding]::ASCII", writer)
        self.assertIn("} catch {", writer)
        calls = set(re.findall(r"Set-StopStatus -Status '([A-Z_]+)'", stopper))
        self.assertEqual(allowed, calls)

        normalizer = installer.split("function NormalizeStopStatus", 1)[1].split(
            "function StopStatusDiagnostic", 1
        )[0]
        for status in allowed:
            with self.subTest(status=status):
                self.assertIn(f"'{status}'", normalizer)
        self.assertIn("else\n    Result := 'INTERNAL_ERROR'", normalizer)

        runner = installer.split("function RunStopSsrvpnProcesses", 1)[1].split(
            "function StopSsrvpnProcesses", 1
        )[0]
        self.assertIn("RequireRecoveryCleanup: Boolean", runner)
        self.assertIn("if RequireRecoveryCleanup then", runner)
        self.assertIn("' -RequireRecoveryCleanup'", runner)
        self.assertIn("GenerateUniqueName(", runner)
        self.assertIn("StopStatusSuffix", runner)
        self.assertIn("' -StatusPath ' + AddQuotes(StatusPath)", runner)
        self.assertIn("LoadStringFromFile(StatusPath, RawStatus)", runner)
        self.assertIn("NormalizeStopStatus(String(RawStatus))", runner)
        self.assertIn("DeleteFile(StatusPath)", runner)
        self.assertEqual(1, runner.count("Exec("))
        log_line = next(line for line in runner.splitlines() if "cleanup exit=" in line)
        self.assertIn("stage=%s", log_line)
        self.assertNotIn("RawStatus", log_line)
        self.assertNotIn("StatusPath", log_line)

        prepare = installer.split(
            "function PrepareToInstall(var NeedsRestart: Boolean): String;", 1
        )[1].split("procedure CurStepChanged", 1)[0]
        uninstall = installer.split("function InitializeUninstall(): Boolean;", 1)[1]
        self.assertGreaterEqual(prepare.count("StopStatusDiagnostic"), 2)
        self.assertGreaterEqual(uninstall.count("StopStatusDiagnostic"), 2)

        tun_capture = tun_helper.split("function Get-SsrvpnTunOwnership", 1)[1]
        tun_capture = tun_capture.split(
            "function Test-SsrvpnTunArtifactsRemoved", 1
        )[0]
        self.assertIn("Get-NetAdapter -IncludeHidden -ErrorAction Stop", tun_capture)
        self.assertNotIn("Meta Tunnel", tun_capture)
        self.assertIn("InterfaceGuid", tun_capture)
        self.assertIn("tun_teardown.pending", tun_capture)
        self.assertIn("ConvertFrom-Json", tun_capture)

        tun_probe = tun_helper.split("function Test-SsrvpnTunArtifactsRemoved", 1)[1]
        tun_probe = tun_probe.split("function Wait-SsrvpnTunTeardown", 1)[0]
        for read_only_probe in (
            "Get-NetAdapter -IncludeHidden",
            "Get-NetIPAddress -ErrorAction Stop",
            "Get-NetRoute -ErrorAction Stop",
        ):
            self.assertIn(read_only_probe, tun_probe)
        for destructive_cmdlet in (
            "Remove-NetAdapter",
            "Remove-NetIPAddress",
            "Remove-NetRoute",
        ):
            self.assertNotIn(destructive_cmdlet, tun_helper)

        tun_wait = tun_helper.split("function Wait-SsrvpnTunTeardown", 1)[1]
        self.assertIn("[AllowEmptyCollection()]", tun_wait)
        self.assertLess(
            tun_wait.index("$OwnedInterfaces.Count -eq 0"),
            tun_wait.index("AddMilliseconds($TimeoutMilliseconds)"),
        )
        self.assertIn("AddMilliseconds($TimeoutMilliseconds)", tun_wait)
        self.assertIn("Start-Sleep -Milliseconds", tun_wait)
        self.assertIn("$TunTeardownTimeoutMilliseconds = 8000", stopper)

        runtime_flow = stopper.split("$installedProcessRunning =", 1)[1]
        capture = runtime_flow.index(
            "$tunOwnership = @(Get-SsrvpnTunOwnership"
        )
        first_stop = runtime_flow.index("foreach ($app in $installedApps)")
        capture_failure = runtime_flow[capture:first_stop]
        self.assertIn("if ($installedProcessRunning)", capture_failure)
        self.assertIn(
            "Set-StopStatus -Status 'TUN_TEARDOWN_PENDING'", capture_failure
        )
        self.assertIn("exit 3", capture_failure)
        remaining_processes = runtime_flow.index("$remainingApps = @(")
        post_stop_capture = runtime_flow.index(
            "$tunOwnership += @(Get-SsrvpnTunOwnership",
            remaining_processes,
        )
        teardown = runtime_flow.index("Wait-SsrvpnTunTeardown")
        post_capture_failure = runtime_flow[post_stop_capture:teardown]
        self.assertIn(
            "Sort-Object ExpectedGuid, OriginalIndex -Unique",
            post_capture_failure,
        )
        self.assertIn(
            "Set-StopStatus -Status 'TUN_TEARDOWN_PENDING'",
            post_capture_failure,
        )
        self.assertIn("exit 3", post_capture_failure)
        success = runtime_flow.index("Set-StopStatus -Status 'OK'")
        self.assertLess(capture, first_stop)
        self.assertLess(remaining_processes, post_stop_capture)
        self.assertLess(post_stop_capture, teardown)
        self.assertLess(teardown, success)

        runtime_test = (
            ROOT / "scripts" / "test_windows_installer_runtime.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("TUN_TEARDOWN_PENDING", runtime_test)
        self.assertIn("-TunTeardownTimeoutMilliseconds", runtime_test)
        self.assertIn(
            "$global:SsrvpnTestProbeMode = $ProbeMode", runtime_test
        )
        self.assertIn(
            "$global:SsrvpnTestAdapterCalls -ge 2", runtime_test
        )
        self.assertNotIn("$script:ProbeMode", runtime_test)
        self.assertIn("'-ProbeMode', 'late-pending'", runtime_test)
        self.assertIn("'-ProbeMode', 'none'", runtime_test)
        self.assertIn("No-TUN cleanup did not report OK.", runtime_test)

    def test_installer_tun_ownership_never_uses_the_generic_adapter_name(
        self,
    ) -> None:
        stopper = (
            ROOT / "SSRVPN_Windows" / "installer" / "stop_ssrvpn_processes.ps1"
        ).read_text(encoding="utf-8")
        tun_helper = (
            ROOT / "SSRVPN_Windows" / "installer" / "tun_ownership.ps1"
        ).read_text(encoding="utf-8")

        ownership = tun_helper[
            tun_helper.index("function Get-SsrvpnTunOwnership") : tun_helper.index(
                "function Test-SsrvpnTunArtifactsRemoved"
            )
        ]
        self.assertNotIn("Meta Tunnel", ownership)
        self.assertIn("tun_teardown.pending", ownership)
        self.assertIn("ConvertFrom-Json", ownership)
        self.assertIn("$markerText -match '^\\d+(,\\d+)*$'", ownership)
        self.assertNotIn("$markerText -match '^\\\\d+(,\\\\d+)*$'", ownership)
        self.assertIn("InterfaceGuid", ownership)
        self.assertIn("baselineInterfaces", ownership)
        self.assertIn("198.18.0.1", ownership)
        self.assertIn("fdfe:dcba:9876::1", ownership)
        self.assertIn("Get-NetRoute", ownership)
        self.assertIn("$discoverFromBaseline", ownership)
        self.assertIn("$discoverFromLegacy", ownership)
        self.assertIn("ConvertTo-Json -Compress -Depth 4", ownership)
        self.assertIn("Move-Item -LiteralPath $markerTempPath", ownership)
        self.assertIn("Legacy TUN ownership could not be verified", ownership)
        self.assertNotIn("$InstalledProcessRunning", ownership)

        residual_probe = tun_helper[
            tun_helper.index("function Test-SsrvpnTunArtifactsRemoved") : tun_helper.index(
                "function Wait-SsrvpnTunTeardown"
            )
        ]
        self.assertIn("InterfaceGuid", residual_probe)
        self.assertIn("ExpectedGuid", residual_probe)
        self.assertIn("OriginalIndex", residual_probe)
        self.assertNotIn("$_.Name", residual_probe)

        runtime_test = (
            ROOT / "scripts" / "test_windows_installer_runtime.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("foreign-same-name", runtime_test)
        self.assertIn("Foreign same-name TUN blocked installer cleanup", runtime_test)
        self.assertIn("owned-marker-pending", runtime_test)
        self.assertIn("Owned TUN residual did not block installer cleanup", runtime_test)
        for legacy_mode in (
            "legacy-signature-pending",
            "legacy-signature-numeric",
            "legacy-foreign-same-name",
            "legacy-single-address",
            "legacy-wrong-route",
            "unmarked-signature",
        ):
            self.assertIn(legacy_mode, runtime_test)
        self.assertIn(
            "was not migrated to the stable TUN GUID",
            runtime_test,
        )
        self.assertIn(
            "A foreign same-name TUN was promoted to SSRVPN ownership",
            runtime_test,
        )
        self.assertIn(
            "A TUN signature without a persistent marker claimed ownership",
            runtime_test,
        )
        self.assertIn(
            "did not fail closed",
            runtime_test,
        )

    def test_installer_terminalizes_restores_and_rejects_stale_journals(
        self,
    ) -> None:
        stopper = (
            ROOT / "SSRVPN_Windows" / "installer" / "stop_ssrvpn_processes.ps1"
        ).read_text(encoding="utf-8")

        corroboration = stopper[
            stopper.index("function Test-JsonActivationCorroboratedByNative") : stopper.index(
                "function Test-RecoveryState"
            )
        ]
        for token in (
            "Valid",
            "RestoreInProgress",
            "ActivationInProgress",
            "EndpointRestoreInProgress",
            "OwnedProxyServer",
            "OwnedProxyOverride",
            "$script:OwnedProxyOverride",
        ):
            self.assertIn(token, corroboration)
        self.assertIn(
            "[string]$Native.OwnedProxyServer -ne "
            "[string]$Json._ownedProxyServer",
            corroboration,
        )

        state_reader = stopper[
            stopper.index("function Get-ProxyRecoveryState") : stopper.index(
                "function Write-NativeRestoreJournal"
            )
        ]
        self.assertIn(
            "activationInProgress = (Test-JsonActivationCorroboratedByNative",
            state_reader,
        )
        self.assertNotIn(
            "activationInProgress = [bool]$json._activationInProgress",
            state_reader,
        )

        terminalizer = stopper[
            stopper.index("function Complete-NativeRestoreJournal") : stopper.index(
                "function Notify-WinInetProxyChange"
            )
        ]
        valid_zero = terminalizer.index(
            "Set-ItemProperty -Path $path -Name Valid -Type DWord -Value 0"
        )
        first_flag_zero = terminalizer.index("'RestoreInProgress'")
        native_delete = terminalizer.index(
            "Remove-Item -Path $path -Recurse -Force"
        )
        self.assertLess(valid_zero, first_flag_zero)
        self.assertLess(first_flag_zero, native_delete)
        self.assertIn("if ($flagsTerminal) { $terminal = $true }", terminalizer)
        self.assertIn("if (-not ($terminal -or $removed))", terminalizer)

        restore = stopper[
            stopper.index("function Restore-OwnedSystemProxy") : stopper.index(
                "function Disable-OwnedSystemProxyEndpoint"
            )
        ]
        endpoint_start = restore.index(
            "Write-NativeRestoreJournal -Backup $backup -EndpointOnly"
        )
        endpoint_end = restore.index("    return", endpoint_start)
        endpoint_restore = restore[endpoint_start:endpoint_end]
        full_start = restore.index(
            "Write-NativeRestoreJournal -Backup $backup", endpoint_end
        )
        full_restore = restore[full_start:]
        for restore_path in (endpoint_restore, full_restore):
            proxy_enable_commit = restore_path.index(
                "Set-ItemProperty -Path $regPath -Name ProxyEnable"
            )
            terminalize = restore_path.index("Complete-NativeRestoreJournal")
            self.assertLess(proxy_enable_commit, terminalize)
            self.assertLess(
                terminalize, restore_path.index("Notify-WinInetProxyChange")
            )
            self.assertLess(
                terminalize, restore_path.index("Remove-ProxyRecoveryState")
            )

        safe_to_stop = stopper[
            stopper.index("function Test-SystemProxySafeToStop") : stopper.index(
                "$apps = @()"
            )
        ]
        disabled_endpoint = safe_to_stop.index(
            "if ([int]$current.ProxyEnable -eq 0) { return $true }"
        )
        journal_gate = safe_to_stop.index(
            "Test-NativeRecoveryJournalNonReplayable"
        )
        self.assertLess(
            disabled_endpoint,
            journal_gate,
        )
        disable_owned = stopper[
            stopper.index("function Disable-OwnedSystemProxyEndpoint") :
            stopper.index("function Test-SystemProxySafeToStop")
        ]
        self.assertIn("[AllowNull()]$Backup", disable_owned)
        self.assertIn("[switch]$RequireRecoveryCleanup", stopper)
        cleanup_failure = stopper[stopper.rindex("if ($proxyRecoveryFailed)") :]
        self.assertIn("if ($RequireRecoveryCleanup)", cleanup_failure)
        self.assertIn(
            "Set-StopStatus -Status 'RECOVERY_CLEANUP_PENDING'",
            cleanup_failure,
        )
        self.assertIn("exit 3", cleanup_failure)

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
        self.assertIn(
            "UninstallRegistryKey =\n"
            "    'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\' +\n"
            "    '{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1';",
            installer,
        )
        self.assertIn(
            "procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);",
            installer,
        )
        self.assertIn(
            "RegDeleteKeyIncludingSubkeys(HKCU, UninstallRegistryKey)",
            installer,
        )
        self.assertIn("{app}\\installer\\stop_ssrvpn_processes.ps1", installer)
        self.assertIn("InstalledAppPath", installer)
        self.assertIn("InstalledLauncherPath", installer)
        uninstall = installer.split("function InitializeUninstall(): Boolean;", 1)[1]
        self.assertIn(
            "RunStopSsrvpnProcesses(\n"
            "    ExpandConstant('{app}\\installer\\stop_ssrvpn_processes.ps1'), True)",
            uninstall,
        )
        self.assertIn(
            "Result := (StopResult = 0) and\n"
            "    AcquireLauncherGate(GateWaitMilliseconds)",
            uninstall,
        )
        self.assertIn("if StopResult = 3 then", uninstall)
        self.assertIn(
            "无法确认 SSRVPN 进程归属或安全恢复系统代理，卸载尚未删除程序文件",
            uninstall,
        )
        self.assertIn("卸载尚未删除程序文件", uninstall)
        messages = installer.split("[Messages]", 1)[1].split("[InstallDelete]", 1)[0]
        self.assertIn("chinesesimp.ConfirmUninstall=", messages)
        self.assertIn("卸载程序仅删除程序文件", messages)
        for preserved_state in ("设置", "订阅", "节点", "本机加密密钥"):
            with self.subTest(preserved_state=preserved_state):
                self.assertIn(preserved_state, messages)
        self.assertIn("供以后重装使用", messages)

        self.assertNotIn("-File $stopper", smoke)
        self.assertIn("$runningInstalledApp = Start-InstalledApp", smoke)
        self.assertIn("$uninstallRegistryPath", smoke)
        self.assertIn("Registry::HKEY_CURRENT_USER", smoke)
        self.assertIn("{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1", smoke)
        self.assertIn("Uninstaller left its registry entry behind", smoke)
        self.assertIn("The uninstaller left the installed SSRVPN app running", smoke)

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
            build_step = workflow.split("- name: Build Windows installer", 1)[1]
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
        self.assertIn("WaitForExit", smoke)
        self.assertIn("TimeoutSeconds = 120", smoke)
        self.assertIn("taskkill.exe", smoke)
        self.assertNotIn("Start-Process -FilePath $installer -Wait", smoke)
        self.assertIn("SSRVPN_Setup.exe", smoke)
        self.assertIn("unins000.exe", smoke)
        self.assertIn("ssrvpn_windows.exe", smoke)
        self.assertIn("bin\\ssrvpn_windows_app.exe", smoke)
        self.assertIn("SSRVPN upgrade", smoke)
        self.assertIn("upgrade-preserve.sentinel", smoke)
        self.assertIn("SSRVPN\\ssrvpn\\upgrade-preserve.sentinel", smoke)
        self.assertIn("SSRVPN\\window_state.json", smoke)
        self.assertIn('"schemaVersion":1', smoke)
        self.assertIn("$sentinel -ne $windowStateSentinel", smoke)
        self.assertIn("SSRVPN.exe\\EBWebView", smoke)
        self.assertIn("vip.ssrvpn.windows\\EBWebView", smoke)
        self.assertIn("upgrade deleted preserved data", smoke)
        self.assertIn("upgrade left WebView cache behind", smoke)
        self.assertGreaterEqual(smoke.count("New-CacheSentinels"), 3)
        self.assertIn("function Start-InstalledApp", smoke)
        self.assertIn(
            "Start-Process -FilePath (Join-Path $installDir "
            "'ssrvpn_windows.exe')",
            smoke,
        )
        self.assertEqual(smoke.count("$upgradeAppProcess = Start-InstalledApp"), 1)
        self.assertEqual(smoke.count("$runningInstalledApp = Start-InstalledApp"), 1)
        upgrade_start = smoke.index("$upgradeAppProcess = Start-InstalledApp")
        upgrade_run = smoke.index("$upgradeExitCode = Invoke-SmokeProcess")
        upgrade_stop_check = smoke.index(
            "SSRVPN upgrade left the previous installed app PID"
        )
        uninstall_start = smoke.index("$runningInstalledApp = Start-InstalledApp")
        self.assertLess(upgrade_start, upgrade_run)
        self.assertLess(upgrade_run, upgrade_stop_check)
        self.assertLess(upgrade_stop_check, uninstall_start)

        invocation = (
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
            "-File ..\\scripts\\test_windows_installer_package.ps1 "
            "-InstallerPath .\\SSRVPN_Setup.exe"
        )
        for workflow_name in ("ci.yml", "release.yml"):
            workflow = (
                ROOT / ".github" / "workflows" / workflow_name
            ).read_text(encoding="utf-8")
            build_step = workflow.split("- name: Build Windows installer", 1)[1]
            build_step = build_step.split("\n      - name:", 1)[0]
            with self.subTest(workflow=workflow_name):
                self.assertIn(invocation, build_step)
                self.assertIn("timeout-minutes: 15", build_step)
                self.assertIn(
                    "$smokeRoot = Join-Path $env:RUNNER_TEMP "
                    "'ssrvpn-process-smoke'",
                    build_step,
                )
                for expected_path_argument in (
                    '-InstalledAppPath "$smokeRoot\\bin\\ssrvpn_windows_app.exe"',
                    '-InstalledLauncherPath "$smokeRoot\\ssrvpn_windows.exe"',
                    '-InstalledCorePath "$smokeRoot\\bin\\mihomo.exe"',
                ):
                    self.assertIn(expected_path_argument, build_step)
                self.assertIn(
                    "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }",
                    build_step,
                )
                log_step = workflow.split(
                    "- name: Upload Windows installer smoke logs", 1
                )[1].split("\n      - name:", 1)[0]
                self.assertIn("if: always()", log_step)

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

    def test_windows_package_prepares_only_the_installer_payload(self) -> None:
        package_script = (
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn('Write-Host "Installer payload: $releaseDir"', package_script)
        self.assertIn("Test-ReleaseHashes -Root $releaseDir", package_script)
        self.assertNotIn("Compress-Archive", package_script)
        self.assertNotIn("SSRVPN.zip", package_script)

    def test_windows_package_rejects_unexpected_build_artifacts(self) -> None:
        package_script = (
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn("$unexpectedBuildArtifacts", package_script)
        self.assertIn("@('.obj', '.pdb')", package_script)
        self.assertIn("$allowedExecutables -notcontains $relativePath", package_script)
        self.assertIn(
            "Release contains unexpected build artifacts", package_script
        )

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
        self.assertIn("$env:LOCALAPPDATA", installer_script)
        self.assertIn("Programs\\Inno Setup 6\\ISCC.exe", installer_script)
        self.assertIn("AppName=SSRVPN Compiler Probe", installer_script)
        self.assertIn("Output=no", installer_script)
        self.assertIn("$probeExitCode", installer_script)
        self.assertIn("Remove-Item -LiteralPath $probePath", installer_script)
        self.assertIn("Compiler engine version:", installer_script)
        self.assertIn("$versionInfo.FileVersion", installer_script)
        self.assertIn("$versionInfo.ProductVersion", installer_script)
        self.assertIn("-gt [version]'0.0.0.0'", installer_script)
        self.assertIn("Inno Setup 6.5", installer_script)

    def test_windows_update_checker_selects_the_installer(self) -> None:
        service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "update_service.dart"
        ).read_text(encoding="utf-8")

        self.assertRegex(service, re.compile(r"assetExtension:\s*'\.exe'"))

    def test_windows_verified_update_uses_native_no_replace_publication(
        self,
    ) -> None:
        shared_service = (
            ROOT
            / "packages"
            / "ssrvpn_shared"
            / "lib"
            / "services"
            / "update_service.dart"
        ).read_text(encoding="utf-8")
        windows_service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "update_service.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("VerifiedUpdateFilePublisher? filePublisher", shared_service)
        self.assertIn("filePublisher(source, destination)", shared_service)
        self.assertIn("CreateHardLinkW", windows_service)
        self.assertIn("_toExtendedLengthPath(source.absolute.path)", windows_service)
        self.assertIn("\\\\\\\\?\\\\UNC\\\\", windows_service)
        runner_manifest = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "runner.exe.manifest"
        ).read_text(encoding="utf-8")
        self.assertIn("<longPathAware", runner_manifest)
        self.assertIn(">true</longPathAware>", runner_manifest)
        self.assertIn(
            "filePublisher: Platform.isWindows ? publishVerifiedInstaller : null",
            windows_service,
        )
        self.assertNotIn("New-Item -ItemType HardLink", shared_service)

    def test_windows_runtime_records_full_core_identity_for_safe_cleanup(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("mihomo.pid", lifecycle)
        self.assertIn("_captureCorePidRecord(", lifecycle)
        identity_start = lifecycle.index("WindowsCoreIdentityEstablishment(")
        self.assertIn("startedProcess,", lifecycle[identity_start:])
        self.assertIn("spawnStartedAtUtcFileTime", lifecycle[identity_start:])
        self.assertIn("spawnReturnedAtUtcFileTime", lifecycle[identity_start:])
        establish = lifecycle.index(
            "await identityEstablishment.establish(", identity_start
        )
        capture = lifecycle.index(
            "capture: _captureCorePidRecord", establish
        )
        persist = lifecycle.index("persist: _writeCorePid", establish)
        current = lifecycle.index(
            "ensureStartCurrent: () => _ensureStartCurrent(startToken)",
            establish,
        )
        publish = lifecycle.index(
            "_corePidRecord = startedPidRecord", establish
        )
        self.assertLess(establish, capture)
        self.assertLess(capture, persist)
        self.assertLess(persist, current)
        self.assertLess(current, publish)
        self.assertIn("creationTimeUtcFileTime", lifecycle)
        self.assertIn("GetProcessTimes(", lifecycle)
        self.assertIn(
            "required WindowsCorePidRecord expectedRecord", lifecycle
        )
        self.assertNotIn("int.tryParse((await pidFile.readAsString())", lifecycle)
        self.assertNotIn("Where-Object { \\$_.ExecutablePath -eq \\$target }", lifecycle)

    def test_installed_launcher_explains_repairing_an_incomplete_install(
        self,
    ) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8")

        self.assertIn("安装目录不完整", launcher)
        self.assertIn("重新运行 SSRVPN_Setup.exe", launcher)


if __name__ == "__main__":
    unittest.main()
