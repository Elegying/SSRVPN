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

[InstallDelete]
Type: filesandordirs; Name: "{app}\*"
Type: filesandordirs; Name: "{localappdata}\SSRVPN\ssrvpn"
Type: files; Name: "{localappdata}\SSRVPN\window_state.json"
Type: filesandordirs; Name: "{localappdata}\SSRVPN\installer-recovery"
Type: files; Name: "{localappdata}\SSRVPN\installer\rebuild-state.json"
Type: dirifempty; Name: "{localappdata}\SSRVPN\installer"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs overwritereadonly restartreplace
Source: "{#ProjectDir}\installer\stop_ssrvpn_processes.ps1"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSRVPN"; Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\ssrvpn_windows.exe"; WorkingDir: "{app}"; Flags: nowait

[Code]
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
begin
  StopResult := StopSsrvpnProcesses;
  if StopResult <> 0 then
    Log(Format('Best-effort process cleanup returned %d', [StopResult]));
  Result := '';
end;
