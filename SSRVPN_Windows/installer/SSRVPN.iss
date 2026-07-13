#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef ProjectDir
  #error ProjectDir is required
#endif

[Setup]
AppId={{299A3A12-B4A8-4120-9A62-CB274F328FE6}
AppName=SSRVPN
AppVersion={#AppVersion}
AppPublisher=SSRVPN
AppPublisherURL=https://github.com/Elegying/SSRVPN
AppSupportURL=https://github.com/Elegying/SSRVPN/issues
AppUpdatesURL=https://github.com/Elegying/SSRVPN/releases
DefaultDirName={localappdata}\Programs\SSRVPN
DefaultGroupName=SSRVPN
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=SSRVPN_Setup
SetupIconFile={#ProjectDir}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\ssrvpn_windows.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
CloseApplicationsFilter=ssrvpn_windows.exe,ssrvpn_windows_app.exe
RestartApplications=no
UsePreviousAppDir=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs overwritereadonly restartreplace
Source: "{#ProjectDir}\installer\prepare_install_directory.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"; Flags: nowait; Check: CanLaunchAfterRestore

[Code]
var
  InstallDataRestoreSucceeded: Boolean;

function CanLaunchAfterRestore: Boolean;
begin
  Result := InstallDataRestoreSucceeded;
end;

function RunInstallDirectoryHelper(Restore: Boolean): Integer;
var
  ResultCode: Integer;
  Started: Boolean;
  PowerShellPath: String;
  ScriptPath: String;
  InstallPath: String;
  DataPath: String;
  RecoveryPath: String;
  StatePath: String;
  Parameters: String;
begin
  ResultCode := -1;
  ExtractTemporaryFile('prepare_install_directory.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\prepare_install_directory.ps1');
  InstallPath := ExpandConstant('{app}');
  DataPath := ExpandConstant('{app}\bin\ssrvpn');
  RecoveryPath := ExpandConstant('{localappdata}\SSRVPN\installer-recovery');
  StatePath := ExpandConstant('{localappdata}\SSRVPN\installer\rebuild-state.json');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
    ' -InstallDir ' + AddQuotes(InstallPath) +
    ' -DataDir ' + AddQuotes(DataPath) +
    ' -RecoveryRoot ' + AddQuotes(RecoveryPath) +
    ' -StateFile ' + AddQuotes(StatePath);
  if Restore then
    Parameters := Parameters + ' -Restore';
  Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  if not Started then begin
    Log('Could not start installation-directory helper');
    Result := -1;
  end else begin
    Result := ResultCode;
  end;
  if Result <> 0 then
    Log(Format('Installation-directory helper returned %d', [Result]));
end;

function PrepareInstallDirectory: Integer;
begin
  Result := RunInstallDirectoryHelper(False);
end;

function RestoreInstallData: Integer;
begin
  Result := RunInstallDirectoryHelper(True);
end;

function StopSsrvpnProcesses: Integer;
var
  ResultCode: Integer;
  Started: Boolean;
  PowerShellPath: String;
  ScriptPath: String;
  InstalledCorePath: String;
  InstalledCorePidPath: String;
  Parameters: String;
begin
  ResultCode := -1;
  ExtractTemporaryFile('stop_ssrvpn_processes.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\stop_ssrvpn_processes.ps1');
  InstalledCorePath := ExpandConstant('{app}\bin\mihomo.exe');
  InstalledCorePidPath := ExpandConstant('{app}\bin\ssrvpn\mihomo.pid');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
    ' -InstalledCorePath ' + AddQuotes(InstalledCorePath) +
    ' -InstalledCorePidPath ' + AddQuotes(InstalledCorePidPath);
  Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  if Started then
    Result := ResultCode
  else
    Result := -1;
  if Result <> 0 then
    Log(Format('SSRVPN process cleanup returned %d; install continues', [Result]));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  StopResult: Integer;
  DirectoryResult: Integer;
begin
  InstallDataRestoreSucceeded := True;
  StopResult := StopSsrvpnProcesses;
  DirectoryResult := PrepareInstallDirectory;
  if StopResult <> 0 then
    Log(Format('Best-effort process cleanup returned %d', [StopResult]));
  if DirectoryResult <> 0 then begin
    Result := 'SSRVPN 无法安全备份或恢复现有数据。安装已停止；' +
      '请保留 %LOCALAPPDATA%\SSRVPN\installer-recovery 后查看安装日志。';
  end else
    Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  RestoreResult: Integer;
begin
  if CurStep = ssPostInstall then begin
    RestoreResult := RestoreInstallData;
    InstallDataRestoreSucceeded := RestoreResult = 0;
    if RestoreResult <> 0 then begin
      Log(Format('Best-effort installation data restore returned %d', [RestoreResult]));
      MsgBox(
        'SSRVPN 已安装，但旧数据尚未安全恢复，因此不会自动启动。' + #13#10 +
        '恢复副本仍保留在 %LOCALAPPDATA%\SSRVPN\installer-recovery。' + #13#10 +
        '请查看安装日志并重新运行安装器。',
        mbError, MB_OK);
    end;
  end;
end;
