param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_REPOSITORY -cne 'Elegying/SSRVPN' -or -not $env:RUNNER_TEMP) {
  throw 'Real installer ownership tests require a disposable GitHub Windows runner.'
}
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path $env:RUNNER_TEMP 'installer-ownership-package'
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
$installDir = Join-Path $root 'installed'
$sourcePayload = Join-Path $root 'verified-payload'
$registryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1'
$otherRegistryPath = $registryPath.Replace('HKLM:', 'HKCU:')
$desktop = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'SSRVPN.lnk'
$menu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'SSRVPN.lnk'
foreach ($path in @($registryPath, $otherRegistryPath, $desktop, $menu)) {
  if (Test-Path -LiteralPath $path) { throw "Runner is not isolated: $path" }
}
$utf8 = [Text.UTF8Encoding]::new($false)
$results = New-Object Collections.ArrayList
function Write-Text([string]$Path, [string]$Value) {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
  [IO.File]::WriteAllText($Path, $Value, $utf8)
}
function Run-Installer([string]$Exe, [string]$Phase, [string]$Directory = $installDir) {
  $log = Join-Path $root "$Phase.log"
  $process = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $Directory + '"'), ('/LOG="' + $log + '"'))
  try {
    if (-not $process.WaitForExit(180000)) { throw "Installer timed out: $Phase (process $($process.Id))" }
    $process.Refresh()
    $code = $process.ExitCode
  } finally { $process.Dispose() }
  Write-Host "$Phase exit=$code log=$log"
  Write-Text (Join-Path $root "$Phase.process.json") ([ordered]@{
    phase = $Phase; exitCode = $code; executableSha256 = (Get-FileHash -LiteralPath $Exe).Hash.ToLowerInvariant(); directory = $Directory
  } | ConvertTo-Json)
  return $code
}
function Snapshot([string]$Name) {
  $files = @()
  if (Test-Path -LiteralPath $installDir) {
    $prefix = $installDir.TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $installDir -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
      [ordered]@{ path = $_.FullName.Substring($prefix.Length); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
  }
  $reg = if (Test-Path -LiteralPath $registryPath) {
    $key = Get-Item -LiteralPath $registryPath
    try {
      @(foreach ($valueName in @($key.GetValueNames() | Sort-Object)) {
        [ordered]@{ name = $valueName; kind = $key.GetValueKind($valueName).ToString(); value = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
      })
    } finally { $key.Dispose() }
  } else { @() }
  $shortcuts = @(foreach ($path in @($desktop, $menu)) {
    [ordered]@{ path = $path; sha256 = $(if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path).Hash } else { 'ABSENT' }) }
  })
  $value = [ordered]@{ files = $files; registry = @($reg); shortcuts = $shortcuts }
  $json = $value | ConvertTo-Json -Depth 6
  Write-Text (Join-Path $root "$Name.json") $json
  return $value
}
function Uninstall-Current([string]$Phase) {
  $text = [string](Get-ItemProperty -LiteralPath $registryPath).UninstallString
  if ($text -notmatch '^"([^"]+)"') { throw 'Unexpected uninstall command.' }
  $exe = $matches[1]
  if (-not $exe.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Uninstaller escaped the disposable test root.' }
  $code = Run-Installer $exe $Phase
  if ($code -ne 0 -or (Test-Path -LiteralPath $registryPath)) { throw 'Real uninstall failed.' }
}
function Build-Candidate([string]$Name, [switch]$Legacy, [switch]$Fault) {
  $buildRoot = Join-Path $root $Name
  $project = Join-Path $buildRoot 'SSRVPN_Windows'
  New-Item -ItemType Directory -Path $buildRoot | Out-Null
  if ($Legacy) {
    $archive = Join-Path $buildRoot 'historical-source.zip'
    & git -C $repo archive --format=zip ('--output=' + $archive) v5.0.18 SSRVPN_Windows/installer SSRVPN_Windows/tool/build_installer.ps1 SSRVPN_Windows/windows/runner/resources/app_icon.ico
    if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve historical installer source.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $buildRoot
  } else {
    New-Item -ItemType Directory -Path (Join-Path $project 'tool'), (Join-Path $project 'windows\runner\resources') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'SSRVPN_Windows\installer') -Destination (Join-Path $project 'installer') -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'SSRVPN_Windows\tool\build_installer.ps1') -Destination (Join-Path $project 'tool')
    Copy-Item -LiteralPath (Join-Path $repo 'SSRVPN_Windows\windows\runner\resources\app_icon.ico') -Destination (Join-Path $project 'windows\runner\resources')
  }
  if ($Fault) {
    $helper = Join-Path $project 'installer\program_files_transaction.ps1'
    $source = [IO.File]::ReadAllText($helper)
    $boundary = 'function Commit-ProgramFilesTransaction {'
    if ([regex]::Matches($source, [regex]::Escape($boundary)).Count -ne 1) { throw 'Fault injection boundary is ambiguous.' }
    $inject = @'

  $faultKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
  try { $entry = $faultKey.OpenSubKey($script:uninstallRegistrySubkey); try { $version = $entry.GetValue('DisplayVersion') } finally { $entry.Dispose() } }
  finally { $faultKey.Dispose() }
  if ($version -cne '9.9.9') { throw 'Fault did not reach the real new HKLM64 uninstall metadata.' }
  throw 'TEST_ONLY_PRE_COMMIT_AFTER_HKLM64'
'@
    Write-Text $helper ($source.Replace($boundary, $boundary + $inject))
  }
  $version = if ($Fault) { '9.9.9' } else { '5.0.19' }
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tool\build_installer.ps1') `
    -SourceDir $sourcePayload -OutputDir $buildRoot -Version $version *> (Join-Path $buildRoot 'compile.log')
  if ($LASTEXITCODE -ne 0) { throw "Fixture installer compile failed: $Name" }
  return (Join-Path $buildRoot 'SSRVPN_Setup.exe')
}
function Assert-UserFiles {
  foreach ($relative in @('unrelated.txt', 'personal\notes.txt', 'bin\ssrvpn\settings.json', 'bin\ssrvpn\subscriptions.json')) {
    $path = Join-Path $installDir $relative
    if (-not (Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path) -cne ('sentinel-' + $relative)) { throw "User file changed: $relative" }
  }
}
function Assert-Committed([string]$Phase) {
  $log = [IO.File]::ReadAllText((Join-Path $root "$Phase.log"))
  if ($log -notmatch 'action=Commit exit=0 stage=COMMITTED\r?\n' -or
      [string](Get-ItemProperty -LiteralPath $registryPath).DisplayVersion -cne '5.0.19' -or
      [string](Get-ItemProperty -LiteralPath $registryPath).UninstallString -notmatch 'installer-state\\[0-9a-f]{32}\\unins000.exe') {
    throw "Installer did not actually commit the candidate: $Phase"
  }
}
function Assert-Recovered([string]$Phase, $Before, $After) {
  $process = [IO.File]::ReadAllText((Join-Path $root "$Phase.process.json")) | ConvertFrom-Json
  if ($process.exitCode -ne 10) { throw "Post-install transaction failure falsely returned success: $Phase" }
  $log = [IO.File]::ReadAllText((Join-Path $root "$Phase.log"))
  if (-not $log.Contains('TEST_ONLY_PRE_COMMIT_AFTER_HKLM64') -or -not $log.Contains('action=Recover exit=0')) {
    throw "The actual installer did not reach successful pre-commit recovery: $Phase"
  }
  foreach ($part in @('files', 'registry', 'shortcuts')) {
    if (($Before[$part] | ConvertTo-Json -Depth 5 -Compress) -cne ($After[$part] | ConvertTo-Json -Depth 5 -Compress)) {
      throw "Recovery did not restore $part exactly: $Phase"
    }
  }
}
function Get-TreeHashes([string]$Directory) {
  return (@(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($Directory.Length); sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash }
  }) | ConvertTo-Json -Depth 4 -Compress)
}
function Get-RecoveryRoot([string]$Directory) {
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { $identity = [BitConverter]::ToString($hasher.ComputeHash($utf8.GetBytes($Directory.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant() }
  finally { $hasher.Dispose() }
  return (Join-Path $env:LOCALAPPDATA "SSRVPN\installer-recovery-v4\$identity")
}
function Invoke-Transaction([string]$Directory, [string]$Action, [string]$Phase) {
  $expected = Join-Path $root 'pending-b.sha256'
  if ($Action -eq 'Begin') {
    $entries = @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object {
      $_.FullName.Substring($Directory.Length + 1) -notmatch '^(installer-state\\|bin\\ssrvpn\\|unrelated\.txt|personal\\)'
    } | ForEach-Object {
      (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() + '  ' + $_.FullName.Substring($Directory.Length + 1)
    })
    Write-Text $expected (($entries -join "`n") + "`n")
  }
  & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'SSRVPN_Windows\installer\program_files_transaction.ps1') `
    -Action $Action -InstallDir $Directory -RecoveryRoot (Get-RecoveryRoot $Directory) -StatusPath (Join-Path $root "$Phase.status") `
    -UninstallRegistrySubkey $registryPath.Substring(6) -UninstallRegistryRoot HKLM -UninstallRegistryView 64 `
    -DesktopShortcutPath $desktop -StartMenuShortcutPath $menu -ExpectedPayloadManifestPath $expected -PayloadSourceRoot $Directory `
    -UninstallMetadataRelativePath ('installer-state\' + [Guid]::NewGuid().ToString('N')) *> (Join-Path $root "$Phase.log")
  if ($LASTEXITCODE -ne 0) { throw "Real production transaction failed: $Phase" }
}
function Pass([string]$Name) { [void]$results.Add([ordered]@{ case = $Name; result = 'PASS' }); Write-Host "PASS $Name" }

try {
  $pins = Get-Content (Join-Path $PSScriptRoot 'windows_legacy_installer_sources.json') -Encoding UTF8 -Raw | ConvertFrom-Json
  $pin = @($pins | Where-Object tag -eq 'v5.0.18')[0]
  $official = Join-Path $root 'official-v5.0.18.exe'
  & curl.exe --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --max-time 180 --output $official $pin.url
  if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $official).Hash.ToLowerInvariant() -cne $pin.sha256) { throw 'Official historical download failed verification.' }
  if ((Run-Installer $official 'official-first-install') -ne 0) { throw 'Official first install failed.' }
  [void](Snapshot 'official-first-install')
  $catalog = Get-Content (Join-Path $repo 'SSRVPN_Windows\installer\legacy-program-catalogs.json') -Encoding UTF8 -Raw | ConvertFrom-Json
  $release = @($catalog.catalogs | Where-Object tag -eq 'v5.0.18')[0]
  foreach ($entry in $release.files) {
    $source = Join-Path $installDir $entry.path
    if ((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne $entry.sha256) { throw "Historical catalog mismatch: $($entry.path)" }
    if ($entry.path -like 'installer\*' -or $entry.path -match '^unins\d+\.') { continue }
    $target = Join-Path $sourcePayload $entry.path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
  }
  Write-Text (Join-Path $installDir 'unrelated.txt') 'must-survive'
  [void](Snapshot 'n03-red-before')
  if ((Run-Installer $official 'n03-red-official-upgrade') -ne 0) { throw 'Baseline official upgrade did not complete.' }
  if (Test-Path -LiteralPath (Join-Path $installDir 'unrelated.txt')) { throw 'Official baseline did not reproduce N03.' }
  [void](Snapshot 'n03-red-after')
  Pass 'N03 red: exact public v5.0.18 upgrade deleted the unrelated sentinel'

  $legacyFault = Build-Candidate 'legacy-fault' -Legacy -Fault
  $before = Snapshot 'n04-red-before'
  [void](Run-Installer $legacyFault 'n04-red-precommit')
  $redLog = [IO.File]::ReadAllText((Join-Path $root 'n04-red-precommit.log'))
  $after = Snapshot 'n04-red-after'
  if (-not $redLog.Contains('TEST_ONLY_PRE_COMMIT_AFTER_HKLM64') -or -not $redLog.Contains('action=Recover exit=0')) { throw 'N04 red did not reach successful production recovery.' }
  if (($before.files | ConvertTo-Json -Depth 4 -Compress) -cne ($after.files | ConvertTo-Json -Depth 4 -Compress)) { throw 'N04 red did not restore the old files.' }
  if ((Get-ItemProperty -LiteralPath $registryPath).DisplayVersion -cne '9.9.9') { throw 'N04 red did not expose stale new HKLM metadata.' }
  Pass 'N04 red: historical successful file recovery left HKLM64 at the new version'
  if ((Run-Installer $official 'restore-baseline') -ne 0) { throw 'Could not restore isolated historical baseline.' }

  foreach ($relative in @('unrelated.txt', 'personal\notes.txt', 'bin\ssrvpn\settings.json', 'bin\ssrvpn\subscriptions.json')) {
    Write-Text (Join-Path $installDir $relative) ('sentinel-' + $relative)
  }
  $candidate = Build-Candidate 'candidate'
  if ((Run-Installer $candidate 'legacy-to-candidate') -ne 0) { throw 'Verified v5.0.18 migration failed.' }
  Assert-Committed 'legacy-to-candidate'
  Assert-UserFiles
  [void](Snapshot 'legacy-to-candidate')
  Pass 'Verified v5.0.18 migration preserves root/nested sentinels and user data'
  if ((Run-Installer $candidate 'normal-upgrade') -ne 0) { throw 'Owned candidate upgrade failed.' }
  Assert-Committed 'normal-upgrade'
  Assert-UserFiles
  Pass 'Normal owned upgrade preserves every user sentinel'

  $fault = Build-Candidate 'candidate-fault' -Fault
  $before = Snapshot 'n04-green-before'
  if (Test-Path -LiteralPath $otherRegistryPath) { throw 'Non-target registry fixture unexpectedly exists.' }
  New-Item -Path $otherRegistryPath -Force | Out-Null
  Set-ItemProperty -LiteralPath $otherRegistryPath -Name 'NonTargetSentinel' -Value 'preserve-hkcu'
  [void](Run-Installer $fault 'n04-green-precommit')
  $greenLog = [IO.File]::ReadAllText((Join-Path $root 'n04-green-precommit.log'))
  $after = Snapshot 'n04-green-after'
  Assert-Recovered 'n04-green-precommit' $before $after
  foreach ($part in @('files', 'registry', 'shortcuts')) {
    if (($before[$part] | ConvertTo-Json -Depth 5 -Compress) -cne ($after[$part] | ConvertTo-Json -Depth 5 -Compress)) { throw "N04 green did not restore $part exactly." }
  }
  if ((Get-ItemProperty -LiteralPath $otherRegistryPath).NonTargetSentinel -cne 'preserve-hkcu') { throw 'Recovery modified non-target HKCU.' }
  Remove-Item -LiteralPath $otherRegistryPath -Recurse
  Assert-UserFiles
  Pass 'N04 green: real post-HKLM pre-commit failure restores all files, HKLM64 and shortcuts; HKCU untouched'

  Uninstall-Current 'candidate-uninstall'
  Assert-UserFiles
  if (Test-Path -LiteralPath (Join-Path $installDir 'ssrvpn_windows.exe')) { throw 'Uninstall left the owned launcher.' }
  if ((Run-Installer $candidate 'candidate-reinstall') -ne 0) { throw 'Reinstall failed.' }
  Assert-Committed 'candidate-reinstall'
  Assert-UserFiles
  Uninstall-Current 'final-uninstall'
  Assert-UserFiles
  Pass 'Real uninstall and reinstall preserve user data and unrelated files'

  $before = Snapshot 'first-failure-before'
  [void](Run-Installer $fault 'first-failure-precommit')
  $after = Snapshot 'first-failure-after'
  Assert-Recovered 'first-failure-precommit' $before $after
  if (Test-Path -LiteralPath $registryPath) { throw 'Failed first install left an uninstall record.' }
  Assert-UserFiles
  Pass 'Real failed first install restores absent HKLM64 and shortcuts without fabricating old values'

  if ((Run-Installer $candidate 'directory-a-install') -ne 0) { throw 'Directory A install failed.' }
  Assert-Committed 'directory-a-install'
  $directoryA = $installDir
  $installDir = Join-Path $root 'directory-b'
  Write-Text (Join-Path $installDir 'unrelated.txt') 'directory-b-sentinel'
  $before = Snapshot 'changed-directory-before'
  [void](Run-Installer $fault 'changed-directory-precommit')
  $after = Snapshot 'changed-directory-after'
  Assert-Recovered 'changed-directory-precommit' $before $after
  Pass 'Real failed directory change restores A registration and shortcuts while leaving B user files'

  if ((Run-Installer $candidate 'directory-b-install') -ne 0) { throw 'Directory B install failed.' }
  Assert-Committed 'directory-b-install'
  $directoryB = $installDir
  $uninstallerB = [string](Get-ItemProperty -LiteralPath $registryPath).UninstallString
  if ($uninstallerB -notmatch '^"([^"]+)"') { throw 'Unexpected directory B uninstaller.' }
  $uninstallerB = $matches[1]
  $installDir = $directoryA
  if ((Run-Installer $candidate 'directory-a-reactivate') -ne 0) { throw 'Directory A reactivation failed.' }
  Assert-Committed 'directory-a-reactivate'
  Invoke-Transaction $directoryB Begin 'directory-b-pending'
  $recoveryB = Get-RecoveryRoot $directoryB
  $beforeRecovery = Get-TreeHashes $recoveryB
  $beforeB = Get-TreeHashes $directoryB
  Write-Text (Join-Path $root 'directory-b-recovery-before.json') $beforeRecovery
  Uninstall-Current 'directory-a-uninstall-with-b-pending'
  if ((Get-TreeHashes $recoveryB) -cne $beforeRecovery -or (Get-TreeHashes $directoryB) -cne $beforeB) { throw 'Uninstall A damaged B or its pending backup.' }
  Write-Text (Join-Path $root 'directory-b-recovery-after-a-uninstall.json') (Get-TreeHashes $recoveryB)
  Invoke-Transaction $directoryB Recover 'directory-b-recover-after-a-uninstall'
  if ((Get-TreeHashes $directoryB) -cne $beforeB -or (Test-Path $registryPath) -or (Test-Path $desktop) -or (Test-Path $menu)) { throw 'B recovery changed files or recreated stale A metadata.' }
  if ((Run-Installer $uninstallerB 'directory-b-final-uninstall' $directoryB) -ne 0) { throw 'B cleanup uninstall failed.' }
  if ([IO.File]::ReadAllText((Join-Path $directoryB 'unrelated.txt')) -cne 'directory-b-sentinel') { throw 'B uninstall deleted its unrelated file.' }
  Pass 'Two real installation directories: uninstall A preserves all B state and backup; later B recovery succeeds'
} finally {
  [ordered]@{ windows = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); commit = $env:GITHUB_SHA; results = @($results.ToArray()) } |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'results.json') -Encoding UTF8
}
