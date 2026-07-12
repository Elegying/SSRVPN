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

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectDir}\installer\migrate_portable_data.ps1"; Flags: dontcopy
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"; Flags: nowait

[Code]
procedure MigrateRunningPortableData;
var
  ResultCode: Integer;
  PowerShellPath: String;
  ScriptPath: String;
  DestinationPath: String;
  Parameters: String;
begin
  ExtractTemporaryFile('migrate_portable_data.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\migrate_portable_data.ps1');
  DestinationPath := ExpandConstant('{app}\bin\ssrvpn');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
    ' -Destination ' + AddQuotes(DestinationPath);
  if not Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) then
    Log('Could not start portable data migration helper')
  else if ResultCode <> 0 then
    Log(Format('Portable data migration helper returned %d', [ResultCode]));
end;

function StopSsrvpnProcesses: Boolean;
var
  ResultCode: Integer;
  PowerShellPath: String;
  ScriptPath: String;
  InstalledCorePath: String;
  Parameters: String;
begin
  ExtractTemporaryFile('stop_ssrvpn_processes.ps1');
  PowerShellPath := ExpandConstant(
    '{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\stop_ssrvpn_processes.ps1');
  InstalledCorePath := ExpandConstant('{app}\bin\mihomo.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File ' + AddQuotes(ScriptPath) +
    ' -InstalledCorePath ' + AddQuotes(InstalledCorePath);
  Result := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log(Format('SSRVPN process cleanup failed with result %d', [ResultCode]));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  MigrateRunningPortableData;
  if not StopSsrvpnProcesses then
    Result := '无法关闭正在运行的 SSRVPN。请先从托盘退出 SSRVPN，' +
      '或在任务管理器中结束 SSRVPN 后重试。'
  else
    Result := '';
end;
