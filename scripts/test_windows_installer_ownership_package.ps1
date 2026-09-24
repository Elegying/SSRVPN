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
  Assert-UserFiles
  [void](Snapshot 'legacy-to-candidate')
  Pass 'Verified v5.0.18 migration preserves root/nested sentinels and user data'
  if ((Run-Installer $candidate 'normal-upgrade') -ne 0) { throw 'Owned candidate upgrade failed.' }
  Assert-UserFiles
  Pass 'Normal owned upgrade preserves every user sentinel'

  $fault = Build-Candidate 'candidate-fault' -Fault
  $before = Snapshot 'n04-green-before'
  New-Item -Path $otherRegistryPath | Out-Null
  Set-ItemProperty -LiteralPath $otherRegistryPath -Name 'NonTargetSentinel' -Value 'preserve-hkcu'
  [void](Run-Installer $fault 'n04-green-precommit')
  $greenLog = [IO.File]::ReadAllText((Join-Path $root 'n04-green-precommit.log'))
  $after = Snapshot 'n04-green-after'
  if (-not $greenLog.Contains('TEST_ONLY_PRE_COMMIT_AFTER_HKLM64') -or -not $greenLog.Contains('action=Recover exit=0')) { throw 'N04 green did not reach successful production recovery.' }
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
  Assert-UserFiles
  Uninstall-Current 'final-uninstall'
  Assert-UserFiles
  Pass 'Real uninstall and reinstall preserve user data and unrelated files'
} finally {
  [ordered]@{ windows = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); commit = $env:GITHUB_SHA; results = @($results.ToArray()) } |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'results.json') -Encoding UTF8
}
