[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstallerPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:GITHUB_ACTIONS -ne 'true') {
  throw 'This destructive installer smoke test may run only on GitHub Actions.'
}
if (-not $env:LOCALAPPDATA) {
  throw 'LOCALAPPDATA is required for the per-user installer smoke test.'
}
if (-not $env:APPDATA) {
  throw 'APPDATA is required for the per-user installer smoke test.'
}

$sourceInstaller = [System.IO.Path]::GetFullPath($InstallerPath)
if ([System.IO.Path]::GetFileName($sourceInstaller) -ne 'SSRVPN_Setup.exe' -or
    -not (Test-Path -LiteralPath $sourceInstaller -PathType Leaf)) {
  throw "SSRVPN_Setup.exe was not found: $sourceInstaller"
}

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\SSRVPN'
$uninstallRegistryPath =
  'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
  '{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1'
$currentUninstallRegistryPath =
  'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
  '{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1'
$uninstallRegistrySubkey =
  'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
  '{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1'
$userDesktopShortcutPath = Join-Path (
  [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
) 'SSRVPN.lnk'
$desktopShortcutPath = Join-Path (
  [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonDesktopDirectory
  )
) 'SSRVPN.lnk'
$userStartMenuShortcutPath = Join-Path (
  [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
) 'SSRVPN.lnk'
$startMenuShortcutPath = Join-Path (
  [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)
) 'SSRVPN.lnk'
if (Test-Path -LiteralPath $installDir) {
  throw "Refusing to overwrite a pre-existing smoke-test install: $installDir"
}

$tempRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$logDir = Join-Path $tempRoot 'ssrvpn-installer-smoke'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$installInstaller = Join-Path $logDir 'SSRVPN_Setup_install.exe'
$manualVersionedInstaller = $null
$manualVersionedRoot = $null
$upgradeInstaller = $null
$upgradeMarker = $null
$upgradeOrphanMarker = $null
$upgradeOwnerToken = $null
$oversizedInstaller = $null
$oversizedMarker = $null
$oversizedRoot = $null
$tamperedInstaller = $null
$tamperedMarker = $null
$tamperedRoot = $null
$delayedLockedInstaller = $null
$delayedLockedMarker = $null
$delayedLockedRoot = $null
$delayedCleanupProcess = $null
$delayedInstallerStream = $null
$replayedInstaller = $null
$replayedMarker = $null
$replayedRoot = $null
$lockedInstaller = $null
$lockedMarker = $null
$lockedRoot = $null
$legacyInstaller = $null
$legacyMarker = $null
$legacyRoot = $null
Copy-Item -LiteralPath $sourceInstaller -Destination $installInstaller -Force
$installLog = Join-Path $logDir 'install.log'
$upgradeLog = Join-Path $logDir 'upgrade.log'
$uninstallLog = Join-Path $logDir 'uninstall.log'
$uninstaller = Join-Path $installDir 'unins000.exe'
$programTransactionHelper = Join-Path $installDir `
  'installer\program_files_transaction.ps1'
$programRecoveryRoot = Join-Path $env:LOCALAPPDATA `
  'SSRVPN\installer-recovery'
$uninstallFailure = $null
$installedAppProcessId = $null
$upgradeAppProcess = $null
$installedAppPath = [System.IO.Path]::GetFullPath(
  (Join-Path $installDir 'bin\ssrvpn_windows_app.exe')
)
$windowStateSentinel = Join-Path $env:LOCALAPPDATA 'SSRVPN\window_state.json'
$validWindowState =
  '{"schemaVersion":1,"left":0,"top":0,"width":1180,"height":760}'
$preservedSentinels = @(
  (Join-Path $installDir 'bin\ssrvpn\upgrade-preserve.sentinel'),
  (Join-Path $env:LOCALAPPDATA 'SSRVPN\ssrvpn\upgrade-preserve.sentinel'),
  $windowStateSentinel
)
$cacheRoots = @(
  (Join-Path $env:APPDATA 'SSRVPN.exe\EBWebView'),
  (Join-Path $env:LOCALAPPDATA 'vip.ssrvpn.windows\EBWebView')
)

function New-CacheSentinels {
  foreach ($cacheRoot in $cacheRoots) {
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    [System.IO.File]::WriteAllText(
      (Join-Path $cacheRoot 'upgrade-delete.sentinel'),
      'ssrvpn-upgrade-delete'
    )
  }
}

function New-LegacyShortcut {
  param([Parameter(Mandatory = $true)][string]$Path)

  New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) `
    -Force | Out-Null
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = Join-Path $installDir 'ssrvpn_windows.exe'
  $shortcut.WorkingDirectory = $installDir
  $shortcut.Save()
}

function Assert-InstallerPreserved {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "SSRVPN deleted the manually supplied installer: $Path"
  }
}

function ConvertFrom-PeVersionMetadataValue {
  param([AllowEmptyString()][string]$Value)

  # PE string fields may be right-padded; no other whitespace is valid here.
  $match = [regex]::Match($Value,
    '\A(?<version>[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)[\x00\x20]*\z')
  if (-not $match.Success) {
    return $null
  }
  return $match.Groups['version'].Value
}

function Test-PeVersionEquivalent {
  param(
    [Parameter(Mandatory = $true)][version]$Actual,
    [Parameter(Mandatory = $true)][version]$Expected
  )

  $actualRevision = if ($Actual.Revision -ge 0) { $Actual.Revision } else { 0 }
  $expectedRevision = if ($Expected.Revision -ge 0) {
    $Expected.Revision
  } else {
    0
  }
  return (
    $Actual.Major -eq $Expected.Major -and
    $Actual.Minor -eq $Expected.Minor -and
    $Actual.Build -eq $Expected.Build -and
    $actualRevision -eq $expectedRevision
  )
}

function Assert-PeVersionMetadataPolicy {
  $nul = [char]0
  $accepted = @(
    [pscustomobject]@{ Raw = '4.0.15'; Canonical = '4.0.15' },
    [pscustomobject]@{ Raw = '4.0.15.0'; Canonical = '4.0.15.0' },
    [pscustomobject]@{ Raw = '4.0.15   '; Canonical = '4.0.15' },
    [pscustomobject]@{ Raw = "4.0.15$nul"; Canonical = '4.0.15' },
    [pscustomobject]@{ Raw = "4.0.15 $nul "; Canonical = '4.0.15' }
  )
  foreach ($case in $accepted) {
    $canonical = ConvertFrom-PeVersionMetadataValue -Value $case.Raw
    if ($canonical -cne $case.Canonical) {
      throw 'PE version metadata policy rejected a valid padding case.'
    }
  }

  $rejected = @(
    '', ' 4.0.15', [string]::Concat([string]$nul, '4.0.15'), '4.0 .15',
    ('4.0' + $nul + '.15'), "4.0.15`t", "4.0.15`r", "4.0.15`n",
    '4.0.15-beta', '4.0.15.0.1',
    (([string][char]0xFF14) + '.0.15')
  )
  foreach ($value in $rejected) {
    if ($null -ne (ConvertFrom-PeVersionMetadataValue -Value $value)) {
      throw 'PE version metadata policy accepted an invalid case.'
    }
  }

  $expected = [version]'4.0.15'
  foreach ($equivalent in @('4.0.15', '4.0.15.0')) {
    if (-not (Test-PeVersionEquivalent `
        -Actual ([version]$equivalent) -Expected $expected)) {
      throw 'PE version metadata policy rejected an equivalent version.'
    }
  }
  foreach ($mismatch in @('5.0.15', '4.1.15', '4.0.16', '4.0.15.1')) {
    if (Test-PeVersionEquivalent `
        -Actual ([version]$mismatch) -Expected $expected) {
      throw 'PE version metadata policy accepted a version mismatch.'
    }
  }
}

function Assert-PeVersionMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [string]$ExpectedInternalName = '',
    [string]$ExpectedOriginalFilename = ''
  )

  $expected = [version]$ExpectedVersion
  $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
  foreach ($propertyName in @('FileVersion', 'ProductVersion')) {
    $value = [string]$versionInfo.$propertyName
    $normalizedValue = ConvertFrom-PeVersionMetadataValue -Value $value
    if ($null -eq $normalizedValue) {
      throw "$Path has invalid PE $propertyName metadata."
    }
    $actual = [version]$normalizedValue
    if (-not (Test-PeVersionEquivalent -Actual $actual -Expected $expected)) {
      throw "$Path has PE $propertyName $normalizedValue; expected $ExpectedVersion."
    }
  }
  if ($ExpectedInternalName -and
      $versionInfo.InternalName -cne $ExpectedInternalName) {
    throw "$Path has PE InternalName $($versionInfo.InternalName); expected $ExpectedInternalName."
  }
  if ($ExpectedOriginalFilename -and
      $versionInfo.OriginalFilename -cne $ExpectedOriginalFilename) {
    throw "$Path has PE OriginalFilename $($versionInfo.OriginalFilename); expected $ExpectedOriginalFilename."
  }
}

function Assert-MicrosoftRuntimeProvenance {
  param([Parameter(Mandatory = $true)][string]$InstallDirectory)

  $runtimeDllNames = @(
    'concrt140.dll',
    'msvcp140.dll',
    'msvcp140_1.dll',
    'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll',
    'msvcp140_codecvt_ids.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll'
  )
  $expectedSourceClasses = @{}
  foreach ($dllName in $runtimeDllNames) {
    $expectedSourceClasses[$dllName] = 'VisualStudioRedist'
    $expectedSourceClasses["bin\$dllName"] = 'VisualStudioRedist'
  }
  $expectedSourceClasses['bin\d3dcompiler_47.dll'] = 'WindowsKitsRedist'

  $provenancePath = Join-Path $InstallDirectory `
    'third_party\MICROSOFT_RUNTIME_PROVENANCE.txt'
  $lines = @(Get-Content -LiteralPath $provenancePath -Encoding UTF8)
  $expectedLineCount = $expectedSourceClasses.Count + 3
  if ($lines.Count -ne $expectedLineCount -or
      $lines[0] -cne '# SSRVPN Microsoft runtime provenance' -or
      $lines[1] -cne 'Format-Version: 1' -or
      $lines[2] -cne "File`tVersion`tSHA256`tSourceClass") {
    throw "Installed Microsoft runtime provenance has an invalid schema: $provenancePath"
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  foreach ($line in $lines[3..($lines.Count - 1)]) {
    $fields = @($line -split "`t")
    if ($fields.Count -ne 4) {
      throw "Installed Microsoft runtime provenance has an invalid record: $line"
    }
    $relativePath = [string]$fields[0]
    $expectedSourceClass = $expectedSourceClasses[$relativePath]
    if (-not $expectedSourceClasses.ContainsKey($relativePath) -or
        -not $seen.Add($relativePath) -or
        [string]$fields[3] -cne $expectedSourceClass) {
      throw "Installed Microsoft runtime provenance has an unexpected record: $relativePath"
    }
    if ([string]::IsNullOrWhiteSpace([string]$fields[1]) -or
        [string]$fields[2] -notmatch '^[a-f0-9]{64}$') {
      throw "Installed Microsoft runtime provenance has invalid identity data: $relativePath"
    }

    $installedPath = Join-Path $InstallDirectory $relativePath
    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
      throw "Installed Microsoft runtime is missing: $relativePath"
    }
    $actualVersion = (
      [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installedPath)
    ).FileVersion -replace '[\r\n\t]', ' '
    $actualHash = (
      Get-FileHash -LiteralPath $installedPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualVersion -cne [string]$fields[1] -or
        $actualHash -cne [string]$fields[2]) {
      throw "Installed Microsoft runtime does not match provenance: $relativePath"
    }
  }
  if ($seen.Count -ne $expectedSourceClasses.Count) {
    throw 'Installed Microsoft runtime provenance is incomplete.'
  }
}

function Wait-PathAbsent {
  param([Parameter(Mandatory = $true)][string]$Path)

  for ($attempt = 0; $attempt -lt 80; $attempt++) {
    if (-not (Test-Path -LiteralPath $Path)) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Post-install cleanup did not delete: $Path"
}

function Assert-NoCleanupQuarantine {
  param([Parameter(Mandatory = $true)][string]$Installer)

  $parent = Split-Path -Path $Installer -Parent
  $leaf = [System.IO.Path]::GetFileName($Installer)
  $residue = @(
    Get-ChildItem -LiteralPath $parent -Force -File `
      -Filter ($leaf + '.ssrvpn-cleanup.*') -ErrorAction Stop
    Get-ChildItem -LiteralPath $parent -Force -File `
      -Filter ($leaf + '.ssrvpn-verified-update.ssrvpn-cleanup.*') `
      -ErrorAction Stop
  )
  if ($residue.Count -ne 0) {
    $residuePaths = $residue.FullName -join ', '
    throw "Post-install cleanup left an isolated installer behind: $residuePaths"
  }
}

function New-VerifiedUpdateAuthorization {
  param([Parameter(Mandatory = $true)][string]$Path)

  $installerName = [System.IO.Path]::GetFileName($Path)
  $digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  $ownerToken = [Guid]::NewGuid().ToString('N') + `
    [Guid]::NewGuid().ToString('N')
  Set-Content -LiteralPath $Path -Stream 'ssrvpn-update-owner' `
    -Value $ownerToken -Encoding ASCII -NoNewline
  $actualOwner = Get-Content -LiteralPath $Path `
    -Stream 'ssrvpn-update-owner' -Encoding ASCII -Raw
  if ([string]$actualOwner -cne $ownerToken) {
    throw "Could not publish the installer owner stream: $Path"
  }
  $markerPath = $Path + '.ssrvpn-verified-update'
  $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText(
    $markerPath,
    "ssrvpn-verified-update-v2`n$installerName`n$digest`n$ownerToken`n",
    $utf8NoBom
  )
  return [PSCustomObject]@{
    MarkerPath = $markerPath
    OwnerToken = $ownerToken
    Sha256 = $digest
  }
}

function Get-DeterministicUpdateNameSuffix {
  param(
    [Parameter(Mandatory = $true)][string]$CanonicalName,
    [Parameter(Mandatory = $true)][string]$Sha256
  )

  if ($Sha256 -notmatch '^[a-f0-9]{64}$') {
    throw "Invalid verified update SHA-256 for $CanonicalName."
  }
  $material = "ssrvpn-windows-update-name-v1`n$CanonicalName`n$Sha256"
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
  } finally {
    $hasher.Dispose()
  }
  return ([BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()).Substring(0, 32)
}

function New-LocalizedOppositeScopeUninstallEntry {
  if (-not (Test-Path -LiteralPath $currentUninstallRegistryPath)) {
    throw "SSRVPN current uninstall entry is missing: $currentUninstallRegistryPath"
  }
  if (Test-Path -LiteralPath $uninstallRegistryPath) {
    throw "Refusing to overwrite an existing opposite-scope uninstall entry: $uninstallRegistryPath"
  }

  $currentValues = Get-ItemProperty -LiteralPath $currentUninstallRegistryPath
  $displayVersion = [string]$currentValues.DisplayVersion
  if ([string]::IsNullOrWhiteSpace($displayVersion)) {
    throw 'SSRVPN current uninstall entry has no DisplayVersion.'
  }
  foreach ($valueName in @('InstallLocation', 'UninstallString')) {
    if ([string]::IsNullOrWhiteSpace([string]$currentValues.$valueName)) {
      throw "SSRVPN current uninstall entry has no $valueName."
    }
  }

  New-Item -Path $uninstallRegistryPath -Force | Out-Null
  $localizedDisplayName = 'SSRVPN {0}{1} {2}' -f `
    [char]0x7248, [char]0x672C, $displayVersion
  Set-ItemProperty -LiteralPath $uninstallRegistryPath `
    -Name DisplayName -Value $localizedDisplayName
  Set-ItemProperty -LiteralPath $uninstallRegistryPath `
    -Name InstallLocation -Value ([string]$currentValues.InstallLocation)
  Set-ItemProperty -LiteralPath $uninstallRegistryPath `
    -Name UninstallString -Value ([string]$currentValues.UninstallString)
}

function Assert-OppositeScopeUninstallEntryRemoved {
  if (Test-Path -LiteralPath $uninstallRegistryPath) {
    throw "SSRVPN left a verified localized opposite-scope uninstall entry behind: $uninstallRegistryPath"
  }
}

function Assert-SingleMachineShortcut {
  foreach ($pair in @(
    @($userDesktopShortcutPath, $desktopShortcutPath),
    @($userStartMenuShortcutPath, $startMenuShortcutPath)
  )) {
    $legacyPath = $pair[0]
    $machinePath = $pair[1]
    if (Test-Path -LiteralPath $legacyPath) {
      throw "SSRVPN left a legacy per-user shortcut behind: $legacyPath"
    }
    if (-not (Test-Path -LiteralPath $machinePath -PathType Leaf)) {
      throw "SSRVPN did not create its machine-wide shortcut: $machinePath"
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($machinePath)
    $actualTarget = [System.IO.Path]::GetFullPath(
      [string]$shortcut.TargetPath
    )
    $expectedTarget = [System.IO.Path]::GetFullPath(
      (Join-Path $installDir 'ssrvpn_windows.exe')
    )
    if (-not [string]::Equals(
        $actualTarget,
        $expectedTarget,
        [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "SSRVPN shortcut targets an unexpected executable: $machinePath"
    }
  }
}

function Start-InstalledApp {
  Start-Process -FilePath (Join-Path $installDir 'ssrvpn_windows.exe') `
    -WorkingDirectory $installDir | Out-Null

  $runningInstalledApp = $null
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $runningInstalledApp = @(
      Get-Process ssrvpn_windows_app -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Path -and [System.IO.Path]::GetFullPath($_.Path).Equals(
            $installedAppPath,
            [System.StringComparison]::OrdinalIgnoreCase
          )
        }
    ) | Select-Object -First 1
    if ($runningInstalledApp) {
      # The production installer intentionally fails closed if any process
      # changes identity during enumeration. Let the launcher/main handoff
      # settle before exercising an upgrade so the smoke fixture represents a
      # stable running installation instead of a first-frame launch race.
      Start-Sleep -Milliseconds 750
      $runningInstalledApp.Refresh()
      if ($runningInstalledApp.HasExited) {
        throw 'The installed app exited before its identity stabilized.'
      }
      return $runningInstalledApp
    }
    Start-Sleep -Milliseconds 250
  }
  throw 'No app from the exact installed path started.'
}

function Invoke-SmokeProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [int]$TimeoutSeconds = 120
  )

  Write-Host "$Phase started. Log: $LogPath"
  # Start-Process -Wait follows the whole descendant tree on Windows, so wait
  # only for the installer process.
  $process = Start-Process -FilePath $FilePath -PassThru `
    -ArgumentList $ArgumentList
  try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
      & $taskkill /F /T /PID $process.Id 2>$null | Out-Null
      throw "$Phase timed out after $TimeoutSeconds seconds. Log: $LogPath"
    }
    $process.Refresh()
    Write-Host "$Phase completed with exit code $($process.ExitCode)."
    return [int]$process.ExitCode
  } finally {
    $process.Dispose()
  }
}

function Get-PostInstallCleanupFixtureArguments {
  param([Parameter(Mandatory = $true)][string]$Installer)

  return @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    "`"$postInstallCleanup`"",
    '-InstalledLauncherPath',
    "`"$(Join-Path $installDir 'ssrvpn_windows.exe')`"",
    '-RemoveVerifiedInstaller',
    '-InstallerPath',
    "`"$Installer`"",
    '-ExpectedInstallerName',
    "`"$([System.IO.Path]::GetFileName($Installer))`"",
    '-InstallerProcessId',
    '2147483647'
  )
}

function Invoke-PostInstallCleanupFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$Phase
  )

  $exitCode = Invoke-SmokeProcess `
    -FilePath $powerShellPath `
    -Phase $Phase `
    -LogPath (Join-Path $logDir ($Phase.Replace(' ', '-') + '.log')) `
    -TimeoutSeconds 15 `
    -ArgumentList @(Get-PostInstallCleanupFixtureArguments `
      -Installer $Installer)
  if ($exitCode -ne 0) {
    throw "$Phase exited with code $exitCode."
  }
}

function New-PendingProgramFileTransaction {
  if (-not (Test-Path -LiteralPath $programTransactionHelper -PathType Leaf)) {
    throw "Installed program transaction helper is missing: $programTransactionHelper"
  }
  if (Test-Path -LiteralPath $programRecoveryRoot) {
    throw "Unexpected pre-existing program recovery root: $programRecoveryRoot"
  }
  $statusPath = Join-Path $logDir 'program-transaction-begin.status'
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $programTransactionHelper `
    -Action Begin `
    -InstallDir $installDir `
    -RecoveryRoot $programRecoveryRoot `
    -StatusPath $statusPath `
    -UninstallRegistrySubkey $uninstallRegistrySubkey `
    -DesktopShortcutPath $desktopShortcutPath `
    -StartMenuShortcutPath $startMenuShortcutPath
  if ($LASTEXITCODE -ne 0) {
    $status = if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
      [System.IO.File]::ReadAllText($statusPath)
    } else {
      'missing status'
    }
    throw "Could not create pending program transaction: $status"
  }
  if (-not (Test-Path -LiteralPath $programRecoveryRoot -PathType Container)) {
    throw 'Program transaction helper did not publish its durable recovery root.'
  }
}

if ([string]::Equals(
    $userDesktopShortcutPath,
    $desktopShortcutPath,
    [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals(
      $userStartMenuShortcutPath,
      $startMenuShortcutPath,
      [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'The smoke runner cannot distinguish user and machine shortcut paths.'
}
foreach ($shortcutPath in @(
  $userDesktopShortcutPath,
  $desktopShortcutPath,
  $userStartMenuShortcutPath,
  $startMenuShortcutPath
)) {
  if (Test-Path -LiteralPath $shortcutPath) {
    throw "Refusing to overwrite a pre-existing smoke-test shortcut: $shortcutPath"
  }
}

Assert-PeVersionMetadataPolicy

try {
  New-LegacyShortcut -Path $userDesktopShortcutPath
  New-LegacyShortcut -Path $userStartMenuShortcutPath
  $installExitCode = Invoke-SmokeProcess `
    -FilePath $installInstaller `
    -Phase 'SSRVPN installer' `
    -LogPath $installLog `
    -ArgumentList @(
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      "/LOG=$installLog"
  )
  if ($installExitCode -ne 0) {
    throw "SSRVPN installer exited with code $installExitCode. Log: $installLog"
  }
  Assert-InstallerPreserved -Path $installInstaller
  Assert-SingleMachineShortcut

  foreach ($relativePath in @(
    'ssrvpn_windows.exe',
    'bin\ssrvpn_windows_app.exe',
    'third_party\THIRD_PARTY_NOTICES.md',
    'third_party\MICROSOFT_RUNTIME_PROVENANCE.txt',
    'third_party\licenses\GPL-3.0.txt',
    'third_party\licenses\SSRVPN-MIT.txt',
    'unins000.exe'
  )) {
    $installedPath = Join-Path $installDir $relativePath
    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
      throw "Installed package is missing $relativePath`: $installDir"
    }
  }
  Assert-MicrosoftRuntimeProvenance -InstallDirectory $installDir

  $currentUninstallValues =
    Get-ItemProperty -LiteralPath $currentUninstallRegistryPath
  $displayVersion = [string]$currentUninstallValues.DisplayVersion
  if ($displayVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
    throw "SSRVPN installer published an invalid display version: $displayVersion"
  }
  Assert-PeVersionMetadata -Path $sourceInstaller `
    -ExpectedVersion $displayVersion
  Assert-PeVersionMetadata `
    -Path (Join-Path $installDir 'ssrvpn_windows.exe') `
    -ExpectedVersion $displayVersion `
    -ExpectedInternalName 'ssrvpn_windows' `
    -ExpectedOriginalFilename 'ssrvpn_windows.exe'
  Assert-PeVersionMetadata `
    -Path (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') `
    -ExpectedVersion $displayVersion `
    -ExpectedInternalName 'ssrvpn_windows_app' `
    -ExpectedOriginalFilename 'ssrvpn_windows_app.exe'

  # The first upgrade from v4.0.14 cannot carry a v2 app-owned marker. Even
  # with the canonical versioned name, that manually supplied package must be
  # retained after a successful overwrite install.
  $manualVersionedRoot = Join-Path $logDir 'manual-versioned-update'
  New-Item -ItemType Directory -Path $manualVersionedRoot | Out-Null
  $manualVersionedInstaller = Join-Path $manualVersionedRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  Copy-Item -LiteralPath $sourceInstaller `
    -Destination $manualVersionedInstaller
  $manualUpgradeExitCode = Invoke-SmokeProcess `
    -FilePath $manualVersionedInstaller `
    -Phase 'unmarked versioned upgrade' `
    -LogPath (Join-Path $logDir 'unmarked-versioned-upgrade.log') `
    -ArgumentList @(
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      "/LOG=$(Join-Path $logDir 'unmarked-versioned-upgrade.log')"
    )
  if ($manualUpgradeExitCode -ne 0) {
    throw "Unmarked versioned upgrade exited with code $manualUpgradeExitCode."
  }
  Assert-InstallerPreserved -Path $manualVersionedInstaller
  if (Test-Path -LiteralPath `
      ($manualVersionedInstaller + '.ssrvpn-verified-update')) {
    throw 'The installer created an app-owned marker for a manual package.'
  }

  $oversizedRoot = Join-Path $logDir 'oversized-update'
  New-Item -ItemType Directory -Path $oversizedRoot | Out-Null
  $oversizedInstaller = Join-Path $oversizedRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  $oversizedMarker = $oversizedInstaller + '.ssrvpn-verified-update'
  $oversizedStream = [System.IO.File]::Open(
    $oversizedInstaller,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None
  )
  try {
    $oversizedStream.SetLength(300MB + 1)
  } finally {
    $oversizedStream.Dispose()
  }
  $oversizedOwnerToken = [Guid]::NewGuid().ToString('N') + `
    [Guid]::NewGuid().ToString('N')
  Set-Content -LiteralPath $oversizedInstaller `
    -Stream 'ssrvpn-update-owner' -Value $oversizedOwnerToken `
    -Encoding ASCII -NoNewline
  $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText(
    $oversizedMarker,
    "ssrvpn-verified-update-v2`n" +
      "SSRVPN_Setup_v$displayVersion.exe`n" +
      "a9f610bc1c031274cd04e9f12d74b35c84ef5600f76b1e5d47d754c62a149759`n" +
      "$oversizedOwnerToken`n",
    $utf8NoBom
  )
  $postInstallCleanup = Join-Path $installDir `
    'installer\post_install_cleanup.ps1'
  $powerShellPath = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
  Invoke-PostInstallCleanupFixture `
    -Installer $oversizedInstaller `
    -Phase 'oversized marked update cleanup guard'
  Assert-InstallerPreserved -Path $oversizedInstaller
  Assert-InstallerPreserved -Path $oversizedMarker
  Remove-Item -LiteralPath $oversizedInstaller -Force
  Remove-Item -LiteralPath $oversizedMarker -Force
  Remove-Item -LiteralPath $oversizedRoot -Force
  $oversizedInstaller = $null
  $oversizedMarker = $null
  $oversizedRoot = $null

  # A normal-sized package with a valid v2 marker and matching owner stream
  # must still be retained when its default stream no longer matches the
  # authorized SHA-256 digest.
  $tamperedRoot = Join-Path $logDir 'tampered-update'
  New-Item -ItemType Directory -Path $tamperedRoot | Out-Null
  $tamperedInstaller = Join-Path $tamperedRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  Copy-Item -LiteralPath $sourceInstaller -Destination $tamperedInstaller
  $tamperedAuthorization = New-VerifiedUpdateAuthorization `
    -Path $tamperedInstaller
  $tamperedMarker = [string]$tamperedAuthorization.MarkerPath
  $mutationStream = [System.IO.File]::Open(
    $tamperedInstaller,
    [System.IO.FileMode]::Append,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None
  )
  try {
    $mutationStream.WriteByte(0)
  } finally {
    $mutationStream.Dispose()
  }
  $tamperedOwner = Get-Content -LiteralPath $tamperedInstaller `
    -Stream 'ssrvpn-update-owner' -Encoding ASCII -Raw
  if ([string]$tamperedOwner -cne
      [string]$tamperedAuthorization.OwnerToken) {
    throw 'The tampered update fixture lost its owner stream.'
  }
  Invoke-PostInstallCleanupFixture `
    -Installer $tamperedInstaller `
    -Phase 'tampered update cleanup guard'
  Assert-InstallerPreserved -Path $tamperedInstaller
  Assert-InstallerPreserved -Path $tamperedMarker
  Assert-NoCleanupQuarantine -Installer $tamperedInstaller

  # The one-shot marker must remain available while another process denies
  # rename/delete access to an otherwise valid package. Once the lock clears,
  # the same helper should finish without leaving a quarantine file behind.
  $delayedLockedRoot = Join-Path $logDir 'delayed-lock-update'
  New-Item -ItemType Directory -Path $delayedLockedRoot | Out-Null
  $delayedLockedInstaller = Join-Path $delayedLockedRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  Copy-Item -LiteralPath $sourceInstaller `
    -Destination $delayedLockedInstaller
  $delayedAuthorization = New-VerifiedUpdateAuthorization `
    -Path $delayedLockedInstaller
  $delayedLockedMarker = [string]$delayedAuthorization.MarkerPath
  $delayedInstallerStream = [System.IO.File]::Open(
    $delayedLockedInstaller,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::None
  )
  try {
    $delayedCleanupProcess = Start-Process `
      -FilePath $powerShellPath `
      -ArgumentList @(Get-PostInstallCleanupFixtureArguments `
        -Installer $delayedLockedInstaller) `
      -WindowStyle Hidden `
      -PassThru
    Start-Sleep -Milliseconds 1500
    $delayedCleanupProcess.Refresh()
    if ($delayedCleanupProcess.HasExited) {
      throw 'The delayed lock update cleanup retry exited before the lock cleared.'
    }
    Assert-InstallerPreserved -Path $delayedLockedInstaller
    Assert-InstallerPreserved -Path $delayedLockedMarker
    Assert-NoCleanupQuarantine -Installer $delayedLockedInstaller
  } finally {
    $delayedInstallerStream.Dispose()
    $delayedInstallerStream = $null
  }
  if (-not $delayedCleanupProcess.WaitForExit(30000)) {
    $delayedCleanupProcess.Kill()
    throw 'The delayed lock update cleanup retry timed out.'
  }
  if ($delayedCleanupProcess.ExitCode -ne 0) {
    throw "The delayed lock update cleanup retry exited with code $($delayedCleanupProcess.ExitCode)."
  }
  $delayedCleanupProcess.Dispose()
  $delayedCleanupProcess = $null
  Wait-PathAbsent -Path $delayedLockedInstaller
  Wait-PathAbsent -Path $delayedLockedMarker
  Assert-NoCleanupQuarantine -Installer $delayedLockedInstaller

  # A sidecar left behind after the original package disappears must not be
  # replayable against a new same-name, same-digest manual copy without ADS.
  $replayedRoot = Join-Path $logDir 'replayed-marker-update'
  New-Item -ItemType Directory -Path $replayedRoot | Out-Null
  $replayedInstaller = Join-Path $replayedRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  Copy-Item -LiteralPath $sourceInstaller -Destination $replayedInstaller
  $replayedAuthorization = New-VerifiedUpdateAuthorization `
    -Path $replayedInstaller
  $replayedMarker = [string]$replayedAuthorization.MarkerPath
  Remove-Item -LiteralPath $replayedInstaller -Force
  Copy-Item -LiteralPath $sourceInstaller -Destination $replayedInstaller
  Invoke-PostInstallCleanupFixture `
    -Installer $replayedInstaller `
    -Phase 'replayed marker cleanup guard'
  Assert-InstallerPreserved -Path $replayedInstaller
  Assert-InstallerPreserved -Path $replayedMarker

  # A readable marker that cannot be consumed must never allow the installer
  # to be deleted.
  $lockedRoot = Join-Path $logDir 'locked-marker-update'
  New-Item -ItemType Directory -Path $lockedRoot | Out-Null
  $lockedInstaller = Join-Path $lockedRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  Copy-Item -LiteralPath $sourceInstaller -Destination $lockedInstaller
  $lockedAuthorization = New-VerifiedUpdateAuthorization `
    -Path $lockedInstaller
  $lockedMarker = [string]$lockedAuthorization.MarkerPath
  $lockedMarkerStream = [System.IO.File]::Open(
    $lockedMarker,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  try {
    Invoke-PostInstallCleanupFixture `
      -Installer $lockedInstaller `
      -Phase 'locked marker cleanup guard'
    Assert-InstallerPreserved -Path $lockedInstaller
    Assert-InstallerPreserved -Path $lockedMarker
    Assert-NoCleanupQuarantine -Installer $lockedInstaller
  } finally {
    $lockedMarkerStream.Dispose()
  }

  # The unpublished v1 format never grants cleanup permission.
  $legacyRoot = Join-Path $logDir 'legacy-marker-update'
  New-Item -ItemType Directory -Path $legacyRoot | Out-Null
  $legacyInstaller = Join-Path $legacyRoot `
    "SSRVPN_Setup_v$displayVersion.exe"
  $legacyMarker = $legacyInstaller + '.ssrvpn-verified-update'
  Copy-Item -LiteralPath $sourceInstaller -Destination $legacyInstaller
  $legacyHash = (Get-FileHash -LiteralPath $legacyInstaller `
    -Algorithm SHA256).Hash.ToLowerInvariant()
  [System.IO.File]::WriteAllText(
    $legacyMarker,
    "ssrvpn-verified-update-v1`n" +
      "SSRVPN_Setup_v$displayVersion.exe`n$legacyHash`n",
    $utf8NoBom
  )
  Invoke-PostInstallCleanupFixture `
    -Installer $legacyInstaller `
    -Phase 'legacy marker cleanup guard'
  Assert-InstallerPreserved -Path $legacyInstaller
  Assert-InstallerPreserved -Path $legacyMarker

  $upgradeCanonicalName = "SSRVPN_Setup_v$displayVersion.exe"
  $upgradeCanonicalInstaller = Join-Path $logDir $upgradeCanonicalName
  $upgradeOrphanMarker = $upgradeCanonicalInstaller + `
    '.ssrvpn-verified-update'
  $upgradePackageSha256 = (Get-FileHash -LiteralPath $sourceInstaller `
    -Algorithm SHA256).Hash.ToLowerInvariant()
  $upgradeNameSuffix = Get-DeterministicUpdateNameSuffix `
    -CanonicalName $upgradeCanonicalName `
    -Sha256 $upgradePackageSha256
  $upgradeInstaller = Join-Path $logDir `
    "SSRVPN_Setup_v${displayVersion}_$upgradeNameSuffix.exe"
  $upgradeMarker = $upgradeInstaller + '.ssrvpn-verified-update'
  foreach ($updatePath in @(
    $upgradeCanonicalInstaller,
    $upgradeOrphanMarker,
    $upgradeInstaller,
    $upgradeMarker
  )) {
    if (Test-Path -LiteralPath $updatePath) {
      throw "Refusing to overwrite a pre-existing update smoke file: $updatePath"
    }
  }
  $upgradeOrphanContent = 'user-or-orphan-sidecar-must-remain-byte-for-byte'
  [System.IO.File]::WriteAllText(
    $upgradeOrphanMarker,
    $upgradeOrphanContent,
    [System.Text.UTF8Encoding]::new($false)
  )
  Copy-Item -LiteralPath $sourceInstaller -Destination $upgradeInstaller
  $upgradeAuthorization = New-VerifiedUpdateAuthorization `
    -Path $upgradeInstaller
  $upgradeMarker = [string]$upgradeAuthorization.MarkerPath
  $upgradeOwnerToken = [string]$upgradeAuthorization.OwnerToken

  New-LocalizedOppositeScopeUninstallEntry

  foreach ($sentinel in $preservedSentinels) {
    New-Item -ItemType Directory -Path (Split-Path -Path $sentinel -Parent) `
      -Force | Out-Null
    $sentinelContent = if ($sentinel -eq $windowStateSentinel) {
      $validWindowState
    } else {
      'ssrvpn-upgrade-preserve'
    }
    [System.IO.File]::WriteAllText($sentinel, $sentinelContent)
  }
  New-CacheSentinels

  $upgradeAppProcess = Start-InstalledApp
  $upgradeAppProcess.Refresh()
  if ($upgradeAppProcess.HasExited) {
    throw 'The installed app exited before the upgrade started.'
  }

  $upgradeExitCode = Invoke-SmokeProcess `
    -FilePath $upgradeInstaller `
    -Phase 'SSRVPN upgrade' `
    -LogPath $upgradeLog `
    -ArgumentList @(
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      "/LOG=$upgradeLog"
  )
  if ($upgradeExitCode -ne 0) {
    throw "SSRVPN upgrade exited with code $upgradeExitCode. Log: $upgradeLog"
  }
  Wait-PathAbsent -Path $upgradeInstaller
  Wait-PathAbsent -Path $upgradeMarker
  if ([System.IO.File]::ReadAllText($upgradeOrphanMarker) -cne
      $upgradeOrphanContent) {
    throw 'Verified alternate update cleanup changed the canonical orphan sidecar.'
  }
  Assert-NoCleanupQuarantine -Installer $upgradeInstaller
  Assert-InstallerPreserved -Path $installInstaller
  Assert-SingleMachineShortcut
  Assert-OppositeScopeUninstallEntryRemoved
  $upgradeAppProcess.Refresh()
  if (-not $upgradeAppProcess.HasExited) {
    throw "SSRVPN upgrade left the previous installed app PID $($upgradeAppProcess.Id) running."
  }
  $upgradeAppProcess.Dispose()
  $upgradeAppProcess = $null
  foreach ($sentinel in $preservedSentinels) {
    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
      throw "SSRVPN upgrade deleted preserved data: $sentinel"
    }
  }
  foreach ($cacheRoot in $cacheRoots) {
    if (Test-Path -LiteralPath $cacheRoot) {
      throw "SSRVPN upgrade left WebView cache behind: $cacheRoot"
    }
  }

  $runningInstalledApp = Start-InstalledApp
  $installedAppProcessId = [int]$runningInstalledApp.Id
  $runningInstalledApp.Dispose()
  New-PendingProgramFileTransaction
} finally {
  if ($null -ne $delayedInstallerStream) {
    $delayedInstallerStream.Dispose()
  }
  if ($null -ne $delayedCleanupProcess) {
    $delayedCleanupProcess.Refresh()
    if (-not $delayedCleanupProcess.HasExited) {
      $delayedCleanupProcess.Kill()
    }
    $delayedCleanupProcess.Dispose()
  }
  if ($null -ne $upgradeAppProcess) {
    $upgradeAppProcess.Dispose()
  }
  if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
    try {
      New-CacheSentinels
      $uninstallExitCode = Invoke-SmokeProcess `
        -FilePath $uninstaller `
        -Phase 'SSRVPN uninstaller' `
        -LogPath $uninstallLog `
        -ArgumentList @(
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          "/LOG=$uninstallLog"
        )
      if ($uninstallExitCode -ne 0) {
        $uninstallFailure =
          "SSRVPN uninstaller exited with code $uninstallExitCode. " +
          "Log: $uninstallLog"
      } else {
        if (Test-Path -LiteralPath $programRecoveryRoot) {
          throw 'SSRVPN uninstall left old program recovery binaries behind.'
        }
        foreach ($sentinel in $preservedSentinels) {
          if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
            throw "SSRVPN uninstall deleted preserved data: $sentinel"
          }
          if ($sentinel -ne $windowStateSentinel -and
              [System.IO.File]::ReadAllText($sentinel) -ne
                'ssrvpn-upgrade-preserve') {
            throw "SSRVPN uninstall changed preserved data: $sentinel"
          }
        }
      }
    } catch {
      $uninstallFailure = $_.Exception.Message
    }
  }
  foreach ($sentinel in $preservedSentinels) {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
  }
  foreach ($cleanupPath in @(
    $installInstaller,
    $manualVersionedInstaller,
    $upgradeInstaller,
    $upgradeMarker,
    $upgradeOrphanMarker,
    $oversizedInstaller,
    $oversizedMarker,
    $tamperedInstaller,
    $tamperedMarker,
    $delayedLockedInstaller,
    $delayedLockedMarker,
    $replayedInstaller,
    $replayedMarker,
    $lockedInstaller,
    $lockedMarker,
    $legacyInstaller,
    $legacyMarker,
    $userDesktopShortcutPath,
    $desktopShortcutPath,
    $userStartMenuShortcutPath,
    $startMenuShortcutPath
  )) {
    if ($cleanupPath) {
      Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
    }
  }
  if ($oversizedRoot) {
    Remove-Item -LiteralPath $oversizedRoot -Force -ErrorAction SilentlyContinue
  }
  foreach ($cleanupRoot in @(
    $manualVersionedRoot,
    $tamperedRoot,
    $delayedLockedRoot,
    $replayedRoot,
    $lockedRoot,
    $legacyRoot
  )) {
    if ($cleanupRoot) {
      Remove-Item -LiteralPath $cleanupRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -LiteralPath $uninstallRegistryPath -Recurse -Force `
    -ErrorAction SilentlyContinue
}

if ($uninstallFailure) {
  throw $uninstallFailure
}
if ($installedAppProcessId -and
    (Get-Process -Id $installedAppProcessId -ErrorAction SilentlyContinue)) {
  throw 'The uninstaller left the installed SSRVPN app running.'
}
foreach ($relativePath in @('ssrvpn_windows.exe', 'bin\ssrvpn_windows_app.exe')) {
  if (Test-Path -LiteralPath (Join-Path $installDir $relativePath)) {
    throw "Uninstaller left an installed executable behind: $relativePath"
  }
}
foreach ($cacheRoot in $cacheRoots) {
  if (Test-Path -LiteralPath $cacheRoot) {
    throw "Uninstaller left WebView cache behind: $cacheRoot"
  }
}
if (Test-Path -LiteralPath $uninstallRegistryPath) {
  throw "Uninstaller left its registry entry behind: $uninstallRegistryPath"
}

Write-Host "Windows installer install/uninstall smoke test passed. Logs: $logDir"
