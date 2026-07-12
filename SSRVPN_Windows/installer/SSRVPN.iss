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

procedure StopSsrvpnProcesses;
var
  ResultCode: Integer;
begin
  { The child name is unique to SSRVPN. /T also stops its mihomo child without }
  { killing unrelated mihomo processes by image name. }
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /T /IM ssrvpn_windows_app.exe', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  Sleep(500);
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /IM ssrvpn_windows.exe', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  MigrateRunningPortableData;
  StopSsrvpnProcesses;
  Result := '';
end;
