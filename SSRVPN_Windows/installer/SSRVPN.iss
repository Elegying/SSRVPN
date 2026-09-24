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
VersionInfoVersion={#AppVersion}
AppPublisher=SSRVPN
AppPublisherURL=https://github.com/Elegying/SSRVPN
AppSupportURL=https://github.com/Elegying/SSRVPN/issues
AppUpdatesURL=https://github.com/Elegying/SSRVPN/releases
DefaultDirName={localappdata}\Programs\SSRVPN
DefaultGroupName=SSRVPN
; Always show the destination page. `no` is the only value that actually offers
; the choice on a machine that already has SSRVPN: `yes` hides the page
; outright, and `auto` hides it whenever Setup finds a previous install under
; the same AppId -- which is every upgrade. `auto` reads like "ask on a first
; install, skip afterwards", but it only ever asks a user who has never
; installed SSRVPN, so a re-install silently keeps the old directory.
; UsePreviousAppDir (below) keeps an upgrade pre-filled with the directory the
; user chose last time, so accepting it stays a single click.
DisableDirPage=no
DisableProgramGroupPage=yes
; SSRVPN and Mihomo normally run elevated so a medium-integrity installer
; cannot verify their image paths or terminate stale instances before an
; upgrade. Keep the per-user destination, but elevate the installer process
; that performs the verified cleanup and transactional file replacement.
PrivilegesRequired=admin
UsedUserAreasWarning=no
MinVersion=10.0.10240
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=SSRVPN_Setup
SetupIconFile={#ProjectDir}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\ssrvpn_windows.exe
UninstallDisplayName=SSRVPN
UninstallLogMode=new
UninstallFilesDir={code:GetUninstallMetadataDir}
Compression=lzma2/ultra64
SolidCompression=yes
SetupLogging=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
; Reuse the destination recorded by a previous install. Without this the
; destination page would reappear on every upgrade prefilled with the default
; path, and a user who had chosen elsewhere would silently get a second copy.
UsePreviousAppDir=yes
InfoBeforeFile={#ProjectDir}\installer\overwrite_notice.zh-CN.txt

[Languages]
Name: "chinesesimp"; MessagesFile: "{#ProjectDir}\installer\languages\ChineseSimplified.isl"

[Messages]
chinesesimp.ConfirmUninstall=确认卸载 %1 吗？%n%n卸载程序仅删除程序文件；设置、订阅、节点和本机加密密钥会保留，供以后重装使用。

[InstallDelete]
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
Source: "{#ProjectDir}\installer\name_based_process_sweep.ps1"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\program_files_transaction.ps1"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\program_file_ownership.ps1"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\program_file_handles.cs"; Flags: dontcopy noencryption
Source: "{#ProjectDir}\installer\legacy-program-catalogs.json"; Flags: dontcopy noencryption
Source: "{#PayloadManifestPath}"; DestName: "ssrvpn_expected_payload.sha256"; Flags: dontcopy noencryption
; Inno extracts into its private staging directory. Only the transaction helper
; can publish program files, using verified handles and exclusive CreateNew.
Source: "{#SourceDir}\*"; DestDir: "{tmp}\payload"; Excludes: "bin\ssrvpn,bin\ssrvpn\*"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\proxy_transaction_state.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\tun_ownership.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\name_based_process_sweep.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\post_install_cleanup.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\program_file_ownership.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\program_file_handles.cs"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall
Source: "{#ProjectDir}\installer\program_files_transaction.ps1"; DestDir: "{tmp}\payload\installer"; Flags: ignoreversion deleteafterinstall; AfterInstall: ValidateProgramFilesTransaction

[Icons]
Name: "{commonprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{commondesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

[Code]
const
  AppInstanceMutexName = 'Local\SSRVPN_Windows_SingleInstance';
  LauncherMutexName = 'Local\SSRVPN_Windows_Launcher';
  WaitObject0 = 0;
  WaitAbandoned = $00000080;
  GateWaitMilliseconds = 10000;
  UpdateHandoffGraceMilliseconds = 3000;
  SynchronizeAccess = $00100000;
  UpdateHandoffEventPrefix = 'Local\SSRVPN_UpdateHandoff_';
  UpdateHandoffRequestSuffix = '.ssrvpn-handoff';
  UpdateHandoffStatusSuffix = '.ssrvpn-handoff-status';
  VerifiedUpdateMarkerSuffix = '.ssrvpn-verified-update';
  VerifiedUpdateExpectedInstallerName =
    'SSRVPN_Setup_v{#AppVersion}.exe';
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
  VerifiedUpdateMarkerPath: String;
  VerifiedUpdateActualInstallerName: String;
  VerifiedUpdateCleanupRequested: Boolean;
  LastStopStatus: String;
  ProgramFilesRecoveryPending: Boolean;
  ProgramFilesTransactionPrepared: Boolean;
  LastProgramFilesTransactionStatus: String;
  UninstallMetadataRelativePath: String;
  InstallSucceeded: Boolean;
  PostInstallCommitFailed: Boolean;

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
function WinGetCurrentProcessId(): Cardinal;
  external 'GetCurrentProcessId@kernel32.dll stdcall';
function IsLowerHexString(Value: String; ExpectedLength: Integer): Boolean;
var
  Index: Integer;
  Character: Char;
begin
  Result := Length(Value) = ExpectedLength;
  if not Result then
    exit;
  for Index := 1 to Length(Value) do
  begin
    Character := Value[Index];
    if not (((Character >= '0') and (Character <= '9')) or
      ((Character >= 'a') and (Character <= 'f'))) then
    begin
      Result := False;
      exit;
    end;
  end;
end;

function IsValidUpdateHandoffToken(Token: AnsiString): Boolean;
begin
  Result := IsLowerHexString(String(Token), 32);
end;

function IsValidVerifiedUpdateInstallerName(InstallerName: String): Boolean;
var
  VariantPrefix: String;
  VariantNonce: String;
begin
  if CompareText(InstallerName, VerifiedUpdateExpectedInstallerName) = 0 then
  begin
    Result := True;
    exit;
  end;
  VariantPrefix := ChangeFileExt(
    VerifiedUpdateExpectedInstallerName, '') + '_';
  Result :=
    (Length(InstallerName) = Length(VariantPrefix) + 32 + Length('.exe')) and
    (CompareText(
      Copy(InstallerName, 1, Length(VariantPrefix)), VariantPrefix) = 0) and
    (CompareText(
      Copy(InstallerName, Length(InstallerName) - 3, 4), '.exe') = 0);
  if not Result then
    exit;
  VariantNonce := Copy(InstallerName, Length(VariantPrefix) + 1, 32);
  Result := IsLowerHexString(VariantNonce, 32);
end;

function WinSetEnvironmentVariable(Name, Value: String): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

function InitializePowerShellEnvironment(): Boolean;
begin
  { Scope is this installer and its children only. Do not inherit PowerShell 7
    or caller-specific module paths into our fixed Windows PowerShell 5.1. }
  Result := WinSetEnvironmentVariable('PSModulePath',
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\Modules'));
  if not Result then
  begin
    Log('SSRVPN could not initialize the Windows PowerShell module path.');
    SuppressibleMsgBox('无法准备安装所需的 Windows 组件，尚未修改程序文件。请重试。',
      mbError, MB_OK, IDOK);
  end;
end;

function InitializeSetup(): Boolean;
var
  HandoffEvent: THandle;
  RequestPath: String;
  Token: AnsiString;
begin
  Result := InitializePowerShellEnvironment();
  if not Result then exit;
  VerifiedUpdateActualInstallerName :=
    ExtractFileName(ExpandConstant('{srcexe}'));
  VerifiedUpdateMarkerPath :=
    ExpandConstant('{srcexe}') + VerifiedUpdateMarkerSuffix;
  if IsValidVerifiedUpdateInstallerName(
      VerifiedUpdateActualInstallerName) and
    FileExists(VerifiedUpdateMarkerPath) then
  begin
    VerifiedUpdateCleanupRequested := True;
    Log('SSRVPN detected a marked in-app update installer.');
  end;
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
    (Status = 'APP_INSTANCE_ACTIVE') or
    (Status = 'IDENTITY_UNVERIFIED') or
    (Status = 'APP_STILL_RUNNING') or
    (Status = 'PROXY_UNSAFE') or
    (Status = 'PROCESSES_STILL_RUNNING') or
    (Status = 'TUN_OWNERSHIP_UNVERIFIED') or
    (Status = 'TUN_TEARDOWN_PENDING') or
    (Status = 'PID_CLEANUP_FAILED') or
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
  // The stopper matches processes by exact shipped image name (ADR-021), so
  // no previous install location needs to be read from the uninstall
  // registry: copies in the previous directory, portable copies, and any
  // other same-named process are all covered by the name-based sweep.
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
  ExtractTemporaryFile('name_based_process_sweep.ps1');
  ExtractTemporaryFile('stop_ssrvpn_processes.ps1');
  Result := RunStopSsrvpnProcesses(
    ExpandConstant('{tmp}\stop_ssrvpn_processes.ps1'), False);
end;

function ProgramFilesRecoveryRoot: String;
begin
  { Separate roots also protect a new B transaction from an older A uninstaller
    whose helper still discards the legacy shared installer-recovery path. }
  Result := ExpandConstant('{localappdata}\SSRVPN\installer-recovery-v4\') +
    GetSHA256OfString(UTF8Encode(Lowercase(ExpandConstant('{app}'))));
end;

function GetUninstallMetadataDir(Param: String): String;
begin
  if UninstallMetadataRelativePath = '' then
    UninstallMetadataRelativePath := 'installer-state\' +
      Copy(GetSHA256OfString(ExpandConstant('{tmp}') +
        IntToStr(WinGetCurrentProcessId) +
        GetDateTimeString('yyyymmddhhnnss', #0, #0)), 1, 32);
  Result := ExpandConstant('{app}\') + UninstallMetadataRelativePath;
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
      ' -UninstallRegistryRoot HKLM -UninstallRegistryView 64' +
      ' -LegacyRecoveryRoot ' + AddQuotes(ExpandConstant('{localappdata}\SSRVPN\installer-recovery')) +
      ' -PayloadSourceRoot ' + AddQuotes(ExpandConstant('{tmp}\payload')) +
      ' -DesktopShortcutPath ' +
        AddQuotes(ExpandConstant('{commondesktop}\SSRVPN.lnk')) +
      ' -StartMenuShortcutPath ' +
        AddQuotes(ExpandConstant('{commonprograms}\SSRVPN.lnk'));
    if Action = 'Begin' then
      Parameters := Parameters + ' -LegacyCatalogPath ' +
        AddQuotes(ExpandConstant('{tmp}\legacy-program-catalogs.json')) +
        ' -UninstallMetadataRelativePath ' + AddQuotes(UninstallMetadataRelativePath);
    if ExpectedPayloadManifestPath <> '' then
      Parameters := Parameters + ' -ExpectedPayloadManifestPath ' +
        AddQuotes(ExpectedPayloadManifestPath);
    Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    if LoadStringFromFile(StatusPath, RawStatus) then
      LastProgramFilesTransactionStatus := Trim(Utf8Decode(RawStatus));
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
    ExtractTemporaryFile('program_file_ownership.ps1');
    ExtractTemporaryFile('program_file_handles.cs');
    if Action = 'Begin' then
    begin
      ExtractTemporaryFile('legacy-program-catalogs.json');
      ExtractTemporaryFiles('{tmp}\payload\*');
      GetUninstallMetadataDir('');
      ExpectedPayloadManifestName := 'ssrvpn_expected_payload.sha256';
    end;
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
      'Install', 'ssrvpn_expected_payload.sha256')) then
    RaiseException(
      'SSRVPN 新程序文件未通过完整性校验，无法继续更新。' +
      '安装器将尝试恢复旧程序；请以安装日志中的恢复结果为准。诊断阶段码：' +
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
    if not AcquireLauncherGate(UpdateHandoffGraceMilliseconds) then
      Log('SSRVPN did not exit during the update handoff grace period; forcing verified process cleanup.');
  end;
  StopResult := StopSsrvpnProcesses;
  if (StopResult = 0) and
    (not AcquireLauncherGate(GateWaitMilliseconds)) then
  begin
    ReleaseInstallGates;
    Result := '无法取得 SSRVPN 安装期启动保护，安装尚未修改程序文件。' + #13#10 +
      '安装器已按路径清理当前安装实例，但启动器仍未释放；' +
      '请稍后重试，如果仍然失败请重启 Windows。';
    exit;
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
        '请以日志中的恢复结果为准；不要删除仍在的恢复材料或个人文件。' + #13#10 +
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
        '请以日志中的恢复结果为准；不要删除仍在的恢复材料或个人文件。' + #13#10 +
        '诊断阶段码：' + BeginFailureStatus + '。';
      exit;
    end;
    Result := '';
  end
  else if LastStopStatus = 'APP_INSTANCE_ACTIVE' then
  begin
    ReleaseInstallGates;
    Result := '仍有 SSRVPN 同名进程无法自动结束（含其他目录或便携版副本），' +
      '安装尚未修改程序文件。' + #13#10 +
      StopStatusDiagnostic + #13#10 +
      '请退出所有 SSRVPN 窗口和托盘实例后重试；如果仍然失败，' +
      '请重启 Windows 后再次安装。';
  end
  else if LastStopStatus = 'TUN_OWNERSHIP_UNVERIFIED' then
  begin
    ReleaseInstallGates;
    Result := '无法解析或确认 SSRVPN 虚拟网卡状态，安装尚未修改程序文件。' + #13#10 +
      StopStatusDiagnostic + #13#10 +
      '请先在客户端断开连接并退出后重试。若仍失败，请保留安装日志反馈，' +
      '不要手动删除网络恢复记录。';
  end
  else if LastStopStatus = 'TUN_TEARDOWN_PENDING' then
  begin
    ReleaseInstallGates;
    Result := 'SSRVPN 虚拟网卡的 IP 或路由尚未确认释放，安装尚未修改程序文件。' + #13#10 +
      StopStatusDiagnostic + #13#10 +
      '请稍后重试；如果仍然失败，请重启 Windows 后再次安装。';
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

procedure LaunchVerifiedUpdatePackageCleanup; forward;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    PostInstallCommitFailed := True;
    if ProgramFilesTransactionPrepared then
    begin
      if (not RunProgramFilesTransaction('Seal', '')) or
        (not CommitProgramFilesTransaction) then
        RaiseException(
          'SSRVPN 无法完成程序文件事务提交。' +
          '安装器将尝试恢复旧程序；请以安装日志中的恢复结果为准。诊断阶段码：' +
          LastProgramFilesTransactionStatus + '。');
    end;
    InstallSucceeded := True;
    PostInstallCommitFailed := False;
    if VerifiedUpdateCleanupRequested then
      LaunchVerifiedUpdatePackageCleanup;
    { Only this installation's HKLM64 record is transactionally owned. }
    ReleaseInstallGates;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if PostInstallCommitFailed then Result := 10;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and PostInstallCommitFailed then
  begin
    WizardForm.FinishedHeadingLabel.Caption := 'SSRVPN 安装未完成';
    WizardForm.FinishedLabel.Caption :=
      '程序文件事务提交失败。退出安装器时将尝试恢复旧程序；' +
      '请以安装日志中的恢复结果为准，保留诊断记录后重试。';
  end;
end;

procedure LaunchPostInstallCleanup;
var
  CleanupPath: String;
  Parameters: String;
  PowerShellPath: String;
  ResultCode: Integer;
begin
  CleanupPath := ExpandConstant(
    '{app}\installer\post_install_cleanup.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(CleanupPath) +
    ' -InstalledLauncherPath ' +
      AddQuotes(ExpandConstant('{app}\ssrvpn_windows.exe'));
  try
    if not ExecAsOriginalUser(
      PowerShellPath, Parameters, '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode) then
      Log('SSRVPN could not start post-install shortcut and package cleanup.');
  except
    Log(
      'SSRVPN post-install shortcut and package cleanup raised an internal exception.');
  end;
end;

procedure LaunchVerifiedUpdatePackageCleanup;
var
  CleanupPath: String;
  Parameters: String;
  PowerShellPath: String;
  ResultCode: Integer;
begin
  CleanupPath := ExpandConstant(
    '{app}\installer\post_install_cleanup.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(CleanupPath) +
    ' -InstalledLauncherPath ' +
      AddQuotes(ExpandConstant('{app}\ssrvpn_windows.exe')) +
    ' -RemoveVerifiedInstaller' +
    ' -InstallerPath ' + AddQuotes(ExpandConstant('{srcexe}')) +
    ' -ExpectedInstallerName ' +
      AddQuotes(VerifiedUpdateActualInstallerName) +
    ' -InstallerProcessId ' + IntToStr(WinGetCurrentProcessId);
  try
    if not ExecAsOriginalUser(
      PowerShellPath, Parameters, '', SW_HIDE, ewNoWait, ResultCode) then
      Log('SSRVPN could not start verified update package cleanup.');
  except
    Log('SSRVPN verified update package cleanup raised an internal exception.');
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
  if InstallSucceeded then
  begin
    LaunchPostInstallCleanup;
  end;
end;

function InitializeUninstall(): Boolean;
var
  StopResult: Integer;
begin
  Result := InitializePowerShellEnvironment();
  if not Result then exit;
  if not HoldInstallGateHandles then
  begin
    SuppressibleMsgBox('无法建立 SSRVPN 卸载期进程保护，卸载尚未删除程序文件。' + #13#10 +
      '请关闭其他安装程序后重试；如果仍然失败，请重启 Windows。',
      mbError, MB_OK, IDOK);
    Result := False;
    exit;
  end;
  StopResult := RunStopSsrvpnProcesses(
    ExpandConstant('{app}\installer\stop_ssrvpn_processes.ps1'), True);
  Result := (StopResult = 0) and
    AcquireLauncherGate(GateWaitMilliseconds);
  if Result then
  begin
    if not RunInstalledProgramFilesTransaction('CheckUninstall') then
    begin
      ReleaseInstallGates;
      SuppressibleMsgBox('无法安全清理上次中断安装留下的程序文件副本，' +
        '卸载尚未删除程序文件。' + #13#10 +
        '诊断阶段码：' + LastProgramFilesTransactionStatus + '。' + #13#10 +
        '请重试卸载；如果仍然失败，请重启 Windows 后再次卸载。',
        mbError, MB_OK, IDOK);
      Result := False;
    end;
    exit;
  end;
  if not Result then
  begin
    ReleaseInstallGates;
    if LastStopStatus = 'APP_INSTANCE_ACTIVE' then
      SuppressibleMsgBox('仍有 SSRVPN 同名进程无法自动结束（含其他目录或便携版副本），' +
        '卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请退出所有 SSRVPN 窗口和托盘实例后重试；如果仍然失败，' +
        '请重启 Windows 后再次卸载。', mbError, MB_OK, IDOK)
    else if LastStopStatus = 'TUN_OWNERSHIP_UNVERIFIED' then
      SuppressibleMsgBox('无法解析或确认 SSRVPN 虚拟网卡状态，卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请先在客户端断开连接并退出后重试。若仍失败，请保留诊断阶段码反馈，' +
        '不要手动删除网络恢复记录。', mbError, MB_OK, IDOK)
    else if LastStopStatus = 'TUN_TEARDOWN_PENDING' then
      SuppressibleMsgBox('SSRVPN 虚拟网卡的 IP 或路由尚未确认释放，卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请稍后重试；如果仍然失败，请重启 Windows 后再次卸载。', mbError, MB_OK, IDOK)
    else if StopResult = 3 then
      SuppressibleMsgBox('无法确认 SSRVPN 进程归属或安全恢复系统代理，卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请退出 SSRVPN，确认 Windows 系统代理和网络正常后重试；' +
        '如果仍然失败，请重启 Windows 后再次卸载。', mbError, MB_OK, IDOK)
    else if StopResult <> 0 then
      SuppressibleMsgBox('无法关闭正在运行的 SSRVPN，卸载尚未删除程序文件。' + #13#10 +
        StopStatusDiagnostic + #13#10 +
        '请退出 SSRVPN 后重试；如果仍然失败，请重启 Windows 后再次卸载。',
        mbError, MB_OK, IDOK)
    else
      SuppressibleMsgBox('无法取得 SSRVPN 卸载期启动保护，卸载尚未删除程序文件。' + #13#10 +
        '请稍后重试；如果仍然失败，请重启 Windows。', mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    if not RunInstalledProgramFilesTransaction('Uninstall') then
      RaiseException('SSRVPN 无法删除已验证的程序文件，现场已保留。诊断阶段码：' +
        LastProgramFilesTransactionStatus);
  end;
end;

procedure DeinitializeUninstall;
begin
  ReleaseInstallGates;
end;
