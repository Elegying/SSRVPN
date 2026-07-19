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

[Messages]
chinesesimp.ConfirmUninstall=确认卸载 %1 吗？%n%n卸载程序仅删除程序文件；设置、订阅、节点和本机加密密钥会保留，供以后重装使用。

[InstallDelete]
Type: files; Name: "{app}\*"
Type: files; Name: "{app}\bin\*"
Type: filesandordirs; Name: "{app}\bin\data"
Type: filesandordirs; Name: "{app}\installer"
Type: filesandordirs; Name: "{localappdata}\SSRVPN\installer-recovery"
Type: files; Name: "{localappdata}\SSRVPN\installer\rebuild-state.json"
Type: dirifempty; Name: "{localappdata}\SSRVPN\installer"
Type: filesandordirs; Name: "{userappdata}\SSRVPN.exe\EBWebView"
Type: filesandordirs; Name: "{localappdata}\vip.ssrvpn.windows\EBWebView"

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\SSRVPN.exe\EBWebView"
Type: filesandordirs; Name: "{localappdata}\vip.ssrvpn.windows\EBWebView"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs overwritereadonly
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "{#ProjectDir}\installer\proxy_transaction_state.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\proxy_transaction_state.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "{#ProjectDir}\installer\tun_ownership.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\tun_ownership.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\ssrvpn_windows.exe"; Description: "{cm:LaunchProgram,SSRVPN}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Code]
const
  AppInstanceMutexName = 'Local\SSRVPN_Windows_SingleInstance';
  LauncherMutexName = 'Local\SSRVPN_Windows_Launcher';
  WaitObject0 = 0;
  WaitAbandoned = $00000080;
  GateWaitMilliseconds = 10000;
  UpdateHandoffWaitMilliseconds = 60000;
  SynchronizeAccess = $00100000;
  UpdateHandoffEventPrefix = 'Local\SSRVPN_UpdateHandoff_';
  UpdateHandoffRequestSuffix = '.ssrvpn-handoff';
  UpdateHandoffStatusSuffix = '.ssrvpn-handoff-status';
  StopStatusSuffix = '.ssrvpn-stop-status';
  UninstallRegistryKey =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1';

var
  AppGateMutex: THandle;
  LauncherGateMutex: THandle;
  LauncherGateOwned: Boolean;
  UpdateHandoffDetected: Boolean;
  UpdateHandoffReady: Boolean;
  UpdateHandoffToken: AnsiString;
  UpdateHandoffStatusPath: String;
  LastStopStatus: String;

function WinCreateMutex(Attributes: Cardinal; InitialOwner: BOOL;
  Name: String): THandle;
  external 'CreateMutexW@kernel32.dll stdcall';
function WinOpenMutex(DesiredAccess: Cardinal; InheritHandle: BOOL;
  Name: String): THandle;
  external 'OpenMutexW@kernel32.dll stdcall';
function WinWaitForSingleObject(Handle: THandle; Milliseconds: Cardinal): Cardinal;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function WinReleaseMutex(Handle: THandle): BOOL;
  external 'ReleaseMutex@kernel32.dll stdcall';
function WinCloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
function WinOpenEvent(DesiredAccess: Cardinal; InheritHandle: BOOL;
  Name: String): THandle;
  external 'OpenEventW@kernel32.dll stdcall';

function IsValidUpdateHandoffToken(Token: AnsiString): Boolean;
var
  Index: Integer;
  Character: AnsiChar;
begin
  Result := Length(Token) = 32;
  if not Result then
    exit;
  for Index := 1 to Length(Token) do
  begin
    Character := Token[Index];
    if not (((Character >= '0') and (Character <= '9')) or
      ((Character >= 'a') and (Character <= 'f'))) then
    begin
      Result := False;
      exit;
    end;
  end;
end;

function InitializeSetup(): Boolean;
var
  HandoffEvent: THandle;
  RequestPath: String;
  Token: AnsiString;
begin
  RequestPath := ExpandConstant('{srcexe}') + UpdateHandoffRequestSuffix;
  UpdateHandoffStatusPath :=
    ExpandConstant('{srcexe}') + UpdateHandoffStatusSuffix;
  if LoadStringFromFile(RequestPath, Token) and
    IsValidUpdateHandoffToken(Token) then
  begin
    HandoffEvent := WinOpenEvent(
      SynchronizeAccess, False, UpdateHandoffEventPrefix + String(Token));
    if HandoffEvent <> 0 then
    begin
      WinCloseHandle(HandoffEvent);
      UpdateHandoffToken := Token;
      UpdateHandoffDetected := True;
      DeleteFile(UpdateHandoffStatusPath);
    end;
  end;
  Result := True;
end;

function IsUpdateHandoffLive: Boolean;
var
  HandoffEvent: THandle;
begin
  HandoffEvent := WinOpenEvent(
    SynchronizeAccess, False,
    UpdateHandoffEventPrefix + String(UpdateHandoffToken));
  Result := HandoffEvent <> 0;
  if Result then
    WinCloseHandle(HandoffEvent);
end;

procedure ReleaseInstallGates;
begin
  if LauncherGateMutex <> 0 then
  begin
    if LauncherGateOwned then
      WinReleaseMutex(LauncherGateMutex);
    WinCloseHandle(LauncherGateMutex);
    LauncherGateMutex := 0;
    LauncherGateOwned := False;
  end;
  if AppGateMutex <> 0 then
  begin
    WinCloseHandle(AppGateMutex);
    AppGateMutex := 0;
  end;
end;

function CreateOrOpenGateMutex(Name: String): THandle;
begin
  Result := WinCreateMutex(0, False, Name);
  if Result = 0 then
    Result := WinOpenMutex(SynchronizeAccess, False, Name);
end;

function HoldInstallGateHandles: Boolean;
begin
  if AppGateMutex = 0 then
    AppGateMutex := CreateOrOpenGateMutex(AppInstanceMutexName);
  if LauncherGateMutex = 0 then
    LauncherGateMutex := CreateOrOpenGateMutex(LauncherMutexName);
  Result := (AppGateMutex <> 0) and (LauncherGateMutex <> 0);
  if not Result then
    ReleaseInstallGates;
end;

function AcquireLauncherGate(WaitMilliseconds: Cardinal): Boolean;
var
  WaitResult: Cardinal;
begin
  if LauncherGateOwned then
  begin
    Result := True;
    exit;
  end;
  WaitResult := WinWaitForSingleObject(
    LauncherGateMutex, WaitMilliseconds);
  LauncherGateOwned := (WaitResult = WaitObject0) or
    (WaitResult = WaitAbandoned);
  Result := LauncherGateOwned;
end;

function NormalizeStopStatus(Status: String): String;
begin
  Status := Trim(Status);
  if (Status = 'OK') or
    (Status = 'LOCK_BUSY') or
    (Status = 'LOCK_FAILED') or
    (Status = 'INSTANCE_GATE_FAILED') or
    (Status = 'IDENTITY_UNVERIFIED') or
    (Status = 'FOREIGN_INSTANCE') or
    (Status = 'APP_STILL_RUNNING') or
    (Status = 'PROXY_UNSAFE') or
    (Status = 'PROCESSES_STILL_RUNNING') or
    (Status = 'TUN_TEARDOWN_PENDING') or
    (Status = 'RECOVERY_CLEANUP_PENDING') or
    (Status = 'INTERNAL_ERROR') then
    Result := Status
  else
    Result := 'INTERNAL_ERROR';
end;

function StopStatusDiagnostic: String;
begin
  Result := '诊断阶段码：' + LastStopStatus + '。';
end;

function RunStopSsrvpnProcesses(ScriptPath: String;
  RequireRecoveryCleanup: Boolean): Integer;
var
  ResultCode: Integer;
  Started: Boolean;
  PowerShellPath: String;
  InstalledAppPath: String;
  InstalledLauncherPath: String;
  InstalledCorePath: String;
  InstalledCorePidPath: String;
  StatusPath: String;
  RawStatus: AnsiString;
  Parameters: String;
begin
  ResultCode := -1;
  LastStopStatus := 'INTERNAL_ERROR';
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  InstalledAppPath := ExpandConstant('{app}\bin\ssrvpn_windows_app.exe');
  InstalledLauncherPath := ExpandConstant('{app}\ssrvpn_windows.exe');
  InstalledCorePath := ExpandConstant('{app}\bin\mihomo.exe');
  InstalledCorePidPath := ExpandConstant('{app}\bin\ssrvpn\mihomo.pid');
  StatusPath := GenerateUniqueName(
    ExpandConstant('{tmp}'), StopStatusSuffix);
  try
    Parameters := '-NoLogo -NoProfile -NonInteractive ' +
      '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
      ' -InstalledAppPath ' + AddQuotes(InstalledAppPath) +
      ' -InstalledLauncherPath ' + AddQuotes(InstalledLauncherPath) +
      ' -InstalledCorePath ' + AddQuotes(InstalledCorePath) +
      ' -InstalledCorePidPath ' + AddQuotes(InstalledCorePidPath) +
      ' -StatusPath ' + AddQuotes(StatusPath);
    if RequireRecoveryCleanup then
      Parameters := Parameters + ' -RequireRecoveryCleanup';
    Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    if Started then
      Result := ResultCode
    else
      Result := -1;
    if LoadStringFromFile(StatusPath, RawStatus) then
      LastStopStatus := NormalizeStopStatus(String(RawStatus));
    if ((Result = 0) and (LastStopStatus <> 'OK')) or
      ((Result <> 0) and (LastStopStatus = 'OK')) then
      LastStopStatus := 'INTERNAL_ERROR';
    Log(Format('SSRVPN process cleanup exit=%d stage=%s', [Result, LastStopStatus]));
  finally
    DeleteFile(StatusPath);
  end;
end;

function StopSsrvpnProcesses: Integer;
begin
  ExtractTemporaryFile('proxy_transaction_state.ps1');
  ExtractTemporaryFile('tun_ownership.ps1');
  ExtractTemporaryFile('stop_ssrvpn_processes.ps1');
  Result := RunStopSsrvpnProcesses(
    ExpandConstant('{tmp}\stop_ssrvpn_processes.ps1'), False);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  StopResult: Integer;
begin
  if not HoldInstallGateHandles then
  begin
    Result := '无法建立 SSRVPN 安装期进程保护，安装尚未修改程序文件。' + #13#10 +
      '请关闭其他安装程序后重试；如果仍然失败，请重启 Windows。';
    exit;
  end;
  if UpdateHandoffDetected then
  begin
    if not IsUpdateHandoffLive then
    begin
      ReleaseInstallGates;
      Result := 'SSRVPN 更新安装器交接已过期，安装尚未修改程序文件。' + #13#10 +
        'SSRVPN 将保持运行；请重新发起更新或退出后手动运行安装包。';
      exit;
    end;
    if not SaveStringToFile(
      UpdateHandoffStatusPath, 'ready:' + UpdateHandoffToken, False) then
    begin
      ReleaseInstallGates;
      Result := '无法确认 SSRVPN 已收到更新安装器接管信号，安装尚未修改程序文件。' + #13#10 +
        'SSRVPN 将保持运行；请退出 SSRVPN 后手动运行已下载的安装包。';
      exit;
    end;
    UpdateHandoffReady := True;
    if not AcquireLauncherGate(UpdateHandoffWaitMilliseconds) then
    begin
      ReleaseInstallGates;
      Result := '等待 SSRVPN 安全退出超时，安装尚未修改程序文件。' + #13#10 +
        'SSRVPN 可能仍在恢复系统代理；请确认网络正常后重试。';
      exit;
    end;
    StopResult := StopSsrvpnProcesses;
  end
  else
  begin
    StopResult := StopSsrvpnProcesses;
    if (StopResult = 0) and
      (not AcquireLauncherGate(GateWaitMilliseconds)) then
    begin
      ReleaseInstallGates;
      Result := '无法取得 SSRVPN 安装期启动保护，安装尚未修改程序文件。' + #13#10 +
        '请稍后重试；如果仍然失败，请重启 Windows。';
      exit;
    end;
  end;
  if StopResult = 0 then
    Result := ''
  else if StopResult = 3 then
  begin
    ReleaseInstallGates;
    Result := '无法确认 SSRVPN 进程归属或安全恢复系统代理，安装尚未修改程序文件。' + #13#10 +
      StopStatusDiagnostic + #13#10 +
      '请退出 SSRVPN，确认 Windows 系统代理和网络正常后重试；' +
      '如果仍然失败，请重启 Windows 后再次安装。';
  end
  else
  begin
    ReleaseInstallGates;
    Result := '无法关闭正在运行的 SSRVPN，安装尚未修改旧数据。' + #13#10 +
      StopStatusDiagnostic + #13#10 +
      '请退出 SSRVPN 后重试；如果仍然失败，请重启 Windows 后再次安装。';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    ReleaseInstallGates;
end;

procedure DeinitializeSetup;
begin
  if UpdateHandoffDetected and (not UpdateHandoffReady) then
    SaveStringToFile(
      UpdateHandoffStatusPath, 'cancelled:' + UpdateHandoffToken, False);
  ReleaseInstallGates;
end;

function InitializeUninstall(): Boolean;
var
  StopResult: Integer;
begin
  if not HoldInstallGateHandles then
  begin
    MsgBox('无法建立 SSRVPN 卸载期进程保护，卸载尚未删除程序文件。' + #13#10 +
      '请关闭其他安装程序后重试；如果仍然失败，请重启 Windows。',
      mbError, MB_OK);
    Result := False;
    exit;
  end;
  StopResult := RunStopSsrvpnProcesses(
    ExpandConstant('{app}\installer\stop_ssrvpn_processes.ps1'), True);
  Result := (StopResult = 0) and
    AcquireLauncherGate(GateWaitMilliseconds);
  if not Result then
  begin
    ReleaseInstallGates;
    if StopResult = 3 then
      MsgBox('无法确认 SSRVPN 进程归属或安全恢复系统代理，卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请退出 SSRVPN，确认 Windows 系统代理和网络正常后重试；' +
        '如果仍然失败，请重启 Windows 后再次卸载。', mbError, MB_OK)
    else if StopResult <> 0 then
      MsgBox('无法关闭正在运行的 SSRVPN，卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请退出 SSRVPN 后重试；如果仍然失败，请重启 Windows 后再次卸载。',
        mbError, MB_OK)
    else
      MsgBox('无法取得 SSRVPN 卸载期启动保护，卸载尚未删除程序文件。' + #13#10 +
        '请稍后重试；如果仍然失败，请重启 Windows。', mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if not RegDeleteKeyIncludingSubkeys(HKCU, UninstallRegistryKey) then
      Log('SSRVPN uninstall registry entry was already absent or could not be removed.');
  end;
end;

procedure DeinitializeUninstall;
begin
  ReleaseInstallGates;
end;
