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
#ifndef PayloadManifestPath
  #error PayloadManifestPath is required
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
CloseApplications=no
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
Type: files; Name: "{localappdata}\SSRVPN\installer\rebuild-state.json"
Type: dirifempty; Name: "{localappdata}\SSRVPN\installer"
Type: filesandordirs; Name: "{userappdata}\SSRVPN.exe\EBWebView"
Type: filesandordirs; Name: "{localappdata}\vip.ssrvpn.windows\EBWebView"

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\SSRVPN.exe\EBWebView"
Type: filesandordirs; Name: "{localappdata}\vip.ssrvpn.windows\EBWebView"

[Files]
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\proxy_transaction_state.ps1"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\tun_ownership.ps1"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\program_files_transaction.ps1"; Flags: dontcopy noencryption
Source: "{#PayloadManifestPath}"; DestName: "ssrvpn_expected_payload.sha256"; Flags: dontcopy noencryption
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "bin\ssrvpn,bin\ssrvpn\*"; Flags: ignoreversion recursesubdirs createallsubdirs overwritereadonly
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "{#ProjectDir}\installer\proxy_transaction_state.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "{#ProjectDir}\installer\tun_ownership.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "{#ProjectDir}\installer\program_files_transaction.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion; AfterInstall: ValidateProgramFilesTransaction

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

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
  ProgramFilesTransactionStatusSuffix = '.ssrvpn-program-files-status';
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
  ProgramFilesRecoveryPending: Boolean;
  ProgramFilesTransactionPrepared: Boolean;
  LastProgramFilesTransactionStatus: String;

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
  ProgramFilesRecoveryPending := DirExists(
    ExpandConstant('{localappdata}\SSRVPN\installer-recovery'));
  ProgramFilesTransactionPrepared := False;
  if ProgramFilesRecoveryPending then
    Log('SSRVPN detected a pending program-file installation transaction.');
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

function ProgramFilesRecoveryRoot: String;
begin
  Result := ExpandConstant('{localappdata}\SSRVPN\installer-recovery');
end;

function RunProgramFilesTransactionScript(Action: String; ScriptPath: String;
  ExpectedPayloadManifestPath: String): Boolean;
var
  ResultCode: Integer;
  Started: Boolean;
  PowerShellPath: String;
  StatusPath: String;
  RawStatus: AnsiString;
  Parameters: String;
begin
  Result := False;
  ResultCode := -1;
  LastProgramFilesTransactionStatus := 'STATUS_MISSING';
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  StatusPath := GenerateUniqueName(
    ExpandConstant('{tmp}'), ProgramFilesTransactionStatusSuffix);
  try
    if not FileExists(ScriptPath) then
    begin
      LastProgramFilesTransactionStatus := 'HELPER_MISSING';
      Log('SSRVPN program-file transaction helper is missing: ' + ScriptPath);
      exit;
    end;
    Parameters := '-NoLogo -NoProfile -NonInteractive ' +
      '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
      ' -Action ' + AddQuotes(Action) +
      ' -InstallDir ' + AddQuotes(ExpandConstant('{app}')) +
      ' -RecoveryRoot ' + AddQuotes(ProgramFilesRecoveryRoot) +
      ' -StatusPath ' + AddQuotes(StatusPath) +
      ' -UninstallRegistrySubkey ' + AddQuotes(UninstallRegistryKey) +
      ' -DesktopShortcutPath ' +
        AddQuotes(ExpandConstant('{autodesktop}\SSRVPN.lnk')) +
      ' -StartMenuShortcutPath ' +
        AddQuotes(ExpandConstant('{autoprograms}\SSRVPN.lnk'));
    if ExpectedPayloadManifestPath <> '' then
      Parameters := Parameters + ' -ExpectedPayloadManifestPath ' +
        AddQuotes(ExpectedPayloadManifestPath);
    Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    if LoadStringFromFile(StatusPath, RawStatus) then
      LastProgramFilesTransactionStatus := Trim(String(RawStatus));
    Result := Started and (ResultCode = 0);
    Log('SSRVPN program-file transaction action=' + Action +
      ' exit=' + IntToStr(ResultCode) +
      ' stage=' + LastProgramFilesTransactionStatus);
  except
    Log('SSRVPN program-file transaction action=' + Action +
      ' raised an internal exception.');
    Result := False;
  end;
  DeleteFile(StatusPath);
end;

function RunProgramFilesTransaction(Action: String;
  ExpectedPayloadManifestName: String): Boolean;
var
  ScriptPath: String;
  ExpectedPayloadManifestPath: String;
begin
  Result := False;
  ScriptPath := ExpandConstant('{tmp}\program_files_transaction.ps1');
  try
    if not FileExists(ScriptPath) then
      ExtractTemporaryFile('program_files_transaction.ps1');
    ExpectedPayloadManifestPath := '';
    if ExpectedPayloadManifestName <> '' then
    begin
      ExpectedPayloadManifestPath := ExpandConstant('{tmp}\') +
        ExpectedPayloadManifestName;
      if not FileExists(ExpectedPayloadManifestPath) then
        ExtractTemporaryFile(ExpectedPayloadManifestName);
    end;
    Result := RunProgramFilesTransactionScript(
      Action, ScriptPath, ExpectedPayloadManifestPath);
  except
    LastProgramFilesTransactionStatus := 'EMBEDDED_HELPER_EXTRACTION_FAILED';
    Log('SSRVPN could not extract the program-file transaction helper.');
  end;
end;

function RunInstalledProgramFilesTransaction(Action: String): Boolean;
begin
  Result := RunProgramFilesTransactionScript(
    Action,
    ExpandConstant('{app}\installer\program_files_transaction.ps1'),
    '');
end;

function RecoverPendingProgramFilesTransaction: Boolean;
begin
  if not DirExists(ProgramFilesRecoveryRoot) then
  begin
    ProgramFilesRecoveryPending := False;
    ProgramFilesTransactionPrepared := False;
    Result := True;
    exit;
  end;
  Result := RunProgramFilesTransaction('Recover', '') and
    (not DirExists(ProgramFilesRecoveryRoot));
  ProgramFilesRecoveryPending := DirExists(ProgramFilesRecoveryRoot);
  if Result then
    ProgramFilesTransactionPrepared := False
  else
    ProgramFilesTransactionPrepared := ProgramFilesRecoveryPending;
end;

function BeginProgramFilesTransaction: Boolean;
var
  HelperSucceeded: Boolean;
begin
  HelperSucceeded := RunProgramFilesTransaction('Begin', '');
  ProgramFilesTransactionPrepared := DirExists(ProgramFilesRecoveryRoot);
  ProgramFilesRecoveryPending := ProgramFilesTransactionPrepared;
  Result := HelperSucceeded and ProgramFilesTransactionPrepared;
end;

function CommitProgramFilesTransaction: Boolean;
var
  HelperSucceeded: Boolean;
begin
  HelperSucceeded := RunProgramFilesTransaction('Commit', '');
  Result := HelperSucceeded;
  if Result then
  begin
    ProgramFilesTransactionPrepared := False;
    ProgramFilesRecoveryPending := DirExists(ProgramFilesRecoveryRoot);
  end;
end;

function ClearProgramFilesForInstall: Boolean;
begin
  Result := RunProgramFilesTransaction('Clear', '') and
    DirExists(ProgramFilesRecoveryRoot);
  ProgramFilesTransactionPrepared := DirExists(ProgramFilesRecoveryRoot);
  ProgramFilesRecoveryPending := ProgramFilesTransactionPrepared;
end;

procedure ValidateProgramFilesTransaction;
begin
  if (not ProgramFilesTransactionPrepared) or
    (not RunProgramFilesTransaction(
      'Validate', 'ssrvpn_expected_payload.sha256')) then
    RaiseException(
      'SSRVPN 新程序文件未通过完整性校验，无法继续更新。' +
      '旧程序将自动恢复。诊断阶段码：' +
      LastProgramFilesTransactionStatus + '。');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  StopResult: Integer;
  BeginFailureStatus: String;
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
  begin
    if not RecoverPendingProgramFilesTransaction then
    begin
      ReleaseInstallGates;
      Result := '检测到上次中断的覆盖安装，但无法完成程序文件恢复。' + #13#10 +
        '为避免覆盖可恢复副本，本次安装已停止。诊断阶段码：' +
        LastProgramFilesTransactionStatus + '。' + #13#10 +
        '请重试安装；如果仍然失败，请重启 Windows 后再次安装。';
      exit;
    end;
    if not BeginProgramFilesTransaction then
    begin
      BeginFailureStatus := LastProgramFilesTransactionStatus;
      if ProgramFilesTransactionPrepared then
        RecoverPendingProgramFilesTransaction;
      ReleaseInstallGates;
      Result := '无法建立 SSRVPN 程序文件回滚点，安装尚未开始覆盖。' + #13#10 +
        '旧程序已尽力恢复；恢复副本会保留到后续安装完成处理。' + #13#10 +
        '诊断阶段码：' + BeginFailureStatus + '。';
      exit;
    end;
    if not ClearProgramFilesForInstall then
    begin
      BeginFailureStatus := LastProgramFilesTransactionStatus;
      if ProgramFilesTransactionPrepared then
        RecoverPendingProgramFilesTransaction;
      ReleaseInstallGates;
      Result := '无法在回滚点保护下清理旧版程序文件，安装尚未写入新版本。' + #13#10 +
        '旧程序已尽力恢复；恢复副本会保留到后续安装完成处理。' + #13#10 +
        '诊断阶段码：' + BeginFailureStatus + '。';
      exit;
    end;
    Result := '';
  end
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
  begin
    if ProgramFilesTransactionPrepared then
    begin
      if not CommitProgramFilesTransaction then
        RaiseException(
          'SSRVPN 无法完成程序文件事务提交。' +
          '旧程序将自动恢复。诊断阶段码：' +
          LastProgramFilesTransactionStatus + '。');
    end;
    ReleaseInstallGates;
  end;
end;

procedure DeinitializeSetup;
begin
  if UpdateHandoffDetected and (not UpdateHandoffReady) then
    SaveStringToFile(
      UpdateHandoffStatusPath, 'cancelled:' + UpdateHandoffToken, False);
  if ProgramFilesTransactionPrepared then
  begin
    if not RecoverPendingProgramFilesTransaction then
      Log(
        'SSRVPN could not finish program-file recovery; the durable backup was retained.');
  end;
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
  if Result then
  begin
    if not RunInstalledProgramFilesTransaction('Discard') then
    begin
      ReleaseInstallGates;
      MsgBox('无法安全清理上次中断安装留下的程序文件副本，' +
        '卸载尚未删除程序文件。' + #13#10 +
        '诊断阶段码：' + LastProgramFilesTransactionStatus + '。' + #13#10 +
        '请重试卸载；如果仍然失败，请重启 Windows 后再次卸载。',
        mbError, MB_OK);
      Result := False;
    end;
    exit;
  end;
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
