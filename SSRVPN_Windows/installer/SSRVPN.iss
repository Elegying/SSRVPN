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
UsePreviousAppDir=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectDir}\installer\migrate_portable_data.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"; Flags: nowait

[Code]
function RunPortableDataMigration(DiscoverOnly: Boolean): Integer;
var
  ResultCode: Integer;
  Started: Boolean;
  PowerShellPath: String;
  ScriptPath: String;
  DestinationPath: String;
  StatePath: String;
  Parameters: String;
begin
  ExtractTemporaryFile('migrate_portable_data.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\migrate_portable_data.ps1');
  DestinationPath := ExpandConstant('{app}\bin\ssrvpn');
  StatePath := ExpandConstant('{tmp}\portable_data_source.txt');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
    ' -Destination ' + AddQuotes(DestinationPath) +
    ' -StateFile ' + AddQuotes(StatePath) +
    ' -SetupSource ' + AddQuotes(ExpandConstant('{src}'));
  if DiscoverOnly then
    Parameters := Parameters + ' -DiscoverOnly';
  Started := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  if not Started then begin
    Log('Could not start portable data migration helper');
    Result := -1;
  end else begin
    Result := ResultCode;
  end;
  if Result <> 0 then
    Log(Format('Portable data migration helper returned %d', [Result]));
end;

function DiscoverPortableData: Integer;
begin
  Result := RunPortableDataMigration(True);
end;

function MigratePortableData: Integer;
begin
  Result := RunPortableDataMigration(False);
end;

function StopSsrvpnProcesses: Boolean;
var
  ResultCode: Integer;
  PowerShellPath: String;
  ScriptPath: String;
  InstalledCorePath: String;
  InstalledCorePidPath: String;
  Parameters: String;
begin
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
  Result := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log(Format('SSRVPN process cleanup failed with result %d', [ResultCode]));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  DiscoveryResult: Integer;
  MigrationResult: Integer;
begin
  DiscoveryResult := DiscoverPortableData;
  if DiscoveryResult = 10 then begin
    Result := '检测到多个便携版 SSRVPN 数据目录，无法安全判断应迁移哪一个。' +
      '请只保留需要迁移的便携版副本后重试。';
    Exit;
  end;
  if DiscoveryResult <> 0 then begin
    Log(Format('Portable data discovery failed with result %d; migration skipped',
      [DiscoveryResult]));
    MsgBox('旧版便携数据检测发生异常（错误码 ' + IntToStr(DiscoveryResult) +
      '），自动迁移已跳过。安装将继续，旧版数据不会被删除；' +
      '如新客户端中没有原订阅，请重新导入订阅。', mbInformation, MB_OK);
  end;
  if not StopSsrvpnProcesses then begin
    Result := '无法关闭正在运行的 SSRVPN。请先从托盘退出 SSRVPN，' +
      '或在任务管理器中结束 SSRVPN 后重试。';
    Exit;
  end;
  if DiscoveryResult = 0 then begin
    MigrationResult := MigratePortableData;
    if MigrationResult <> 0 then begin
      Result := '便携版数据迁移失败（错误码 ' + IntToStr(MigrationResult) +
        '）。为避免丢失订阅和设置，安装已停止。请重试；' +
        '如果仍然失败，请先备份旧版 ssrvpn 数据目录。';
      Exit;
    end;
  end;
  Result := '';
end;
