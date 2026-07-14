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
InfoBeforeFile={#ProjectDir}\installer\overwrite_notice.zh-CN.txt

[Languages]
Name: "chinesesimp"; MessagesFile: "{#ProjectDir}\installer\languages\ChineseSimplified.isl"

[InstallDelete]
Type: filesandordirs; Name: "{app}\*"
Type: filesandordirs; Name: "{localappdata}\SSRVPN\ssrvpn"
Type: files; Name: "{localappdata}\SSRVPN\window_state.json"
Type: filesandordirs; Name: "{localappdata}\SSRVPN\installer-recovery"
Type: files; Name: "{localappdata}\SSRVPN\installer\rebuild-state.json"
Type: dirifempty; Name: "{localappdata}\SSRVPN\installer"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs overwritereadonly
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"; Flags: nowait

[Code]
function RunStopSsrvpnProcesses(ScriptPath: String): Integer;
var
  ResultCode: Integer;
  Started: Boolean;
  PowerShellPath: String;
  InstalledAppPath: String;
  InstalledLauncherPath: String;
  InstalledCorePath: String;
  InstalledCorePidPath: String;
  Parameters: String;
begin
  ResultCode := -1;
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  InstalledAppPath := ExpandConstant('{app}\bin\ssrvpn_windows_app.exe');
  InstalledLauncherPath := ExpandConstant('{app}\ssrvpn_windows.exe');
  InstalledCorePath := ExpandConstant('{app}\bin\mihomo.exe');
  InstalledCorePidPath := ExpandConstant('{app}\bin\ssrvpn\mihomo.pid');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
    ' -InstalledAppPath ' + AddQuotes(InstalledAppPath) +
    ' -InstalledLauncherPath ' + AddQuotes(InstalledLauncherPath) +
    ' -InstalledCorePath ' + AddQuotes(InstalledCorePath) +
    ' -InstalledCorePidPath ' + AddQuotes(InstalledCorePidPath);
  Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  if Started then
    Result := ResultCode
  else
    Result := -1;
  if Result <> 0 then
    Log(Format('SSRVPN process cleanup returned %d', [Result]));
end;

function StopSsrvpnProcesses: Integer;
begin
  ExtractTemporaryFile('stop_ssrvpn_processes.ps1');
  Result := RunStopSsrvpnProcesses(
    ExpandConstant('{tmp}\stop_ssrvpn_processes.ps1'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  StopResult: Integer;
begin
  StopResult := StopSsrvpnProcesses;
  if StopResult = 0 then
    Result := ''
  else
    Result := '无法关闭正在运行的 SSRVPN，安装尚未修改旧数据。' + #13#10 +
      '请退出 SSRVPN 后重试；如果仍然失败，请重启 Windows 后再次安装。';
end;

function InitializeUninstall(): Boolean;
var
  StopResult: Integer;
begin
  StopResult := RunStopSsrvpnProcesses(
    ExpandConstant('{app}\installer\stop_ssrvpn_processes.ps1'));
  Result := StopResult = 0;
  if not Result then
    MsgBox('无法关闭正在运行的 SSRVPN，卸载尚未删除程序文件。' + #13#10 +
      '请退出 SSRVPN 后重试；如果仍然失败，请重启 Windows 后再次卸载。',
      mbError, MB_OK);
end;
