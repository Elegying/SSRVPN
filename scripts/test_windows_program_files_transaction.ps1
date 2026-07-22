$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Path $PSScriptRoot -Parent
$transactionScript = Join-Path $root `
  'SSRVPN_Windows\installer\program_files_transaction.ps1'
if (-not (Test-Path -LiteralPath $transactionScript -PathType Leaf)) {
  throw "Program-file transaction helper was not found: $transactionScript"
}

$tempBase = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$testToken = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $tempBase "ssrvpn-program-transaction-$testToken"
$installDir = Join-Path $testRoot 'installed'
$recoveryRoot = Join-Path $testRoot 'installer-recovery'
$statusRoot = Join-Path $testRoot 'status'
$expectedPayloadManifestPath = Join-Path $statusRoot 'expected-payload.sha256'
$userDataPath = Join-Path $installDir 'bin\ssrvpn\user-data.sentinel'
$uninstallRegistrySubkey =
  "Software\Microsoft\Windows\CurrentVersion\Uninstall\SSRVPN-Test-$testToken"
$desktopShortcutPath = Join-Path $testRoot 'desktop\SSRVPN.lnk'
$startMenuShortcutPath = Join-Path $testRoot 'start-menu\SSRVPN.lnk'
$lockedStream = $null

function Invoke-Transaction {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Begin', 'Recover', 'Clear', 'Validate', 'Commit', 'Discard')]
    [string]$Action,
    [switch]$ExpectFailure
  )

  New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
  $statusPath = Join-Path $statusRoot `
    "$Action-$([Guid]::NewGuid().ToString('N')).status"
  $process = Start-Process powershell.exe -PassThru -Wait -WindowStyle Hidden `
    -ArgumentList @(
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', $transactionScript,
      '-Action', $Action,
      '-InstallDir', $installDir,
      '-RecoveryRoot', $recoveryRoot,
      '-StatusPath', $statusPath,
      '-UninstallRegistrySubkey', $uninstallRegistrySubkey,
      '-DesktopShortcutPath', $desktopShortcutPath,
      '-StartMenuShortcutPath', $startMenuShortcutPath,
      '-ExpectedPayloadManifestPath', $expectedPayloadManifestPath
    )
  try {
    if ($ExpectFailure) {
      if ($process.ExitCode -eq 0) {
        throw "$Action unexpectedly succeeded during fault injection."
      }
    } elseif ($process.ExitCode -ne 0) {
      $status = if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($statusPath)
      } else {
        'missing status'
      }
      throw "$Action failed with exit code $($process.ExitCode): $status"
    }
  } finally {
    $process.Dispose()
  }
}

function Write-ExpectedPayloadManifest {
  param([switch]$UppercasePaths)

  $installPrefix = [System.IO.Path]::GetFullPath($installDir).TrimEnd('\') + '\'
  $lines = @(
    Get-ChildItem -LiteralPath $installDir -Recurse -File -Force |
      Where-Object {
        -not $_.FullName.StartsWith(
          ([System.IO.Path]::GetFullPath(
              (Join-Path $installDir 'bin\ssrvpn')
            ).TrimEnd('\') + '\'),
          [System.StringComparison]::OrdinalIgnoreCase
        ) -and $_.Name -notmatch '^unins\d+\.(?:exe|dat|msg)$'
      } |
      Sort-Object FullName |
      ForEach-Object {
        $relativePath = $_.FullName.Substring($installPrefix.Length)
        if ($UppercasePaths) {
          $relativePath = $relativePath.ToUpperInvariant()
        }
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        "$($hash.ToLowerInvariant())  $relativePath"
      }
  )
  New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
  [System.IO.File]::WriteAllText(
    $expectedPayloadManifestPath,
    (($lines -join "`n") + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Write-TestFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $parent = [System.IO.Path]::GetDirectoryName($Path)
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [System.IO.File]::WriteAllText(
    $Path,
    $Value,
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Assert-Text {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
      [System.IO.File]::ReadAllText($Path) -cne $Expected) {
    throw $Message
  }
}

function Set-TestUninstallMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][byte]$Marker
  )

  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
    $uninstallRegistrySubkey)
  try {
    $key.SetValue(
      'DisplayVersion',
      $Version,
      [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue(
      'BinarySentinel',
      [byte[]]@($Marker, 2, 3),
      [Microsoft.Win32.RegistryValueKind]::Binary)
  } finally {
    $key.Close()
  }
}

function Remove-TestUninstallMetadata {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $uninstallRegistrySubkey, $false)
  if ($null -eq $key) { return }
  $key.Close()
  [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
    $uninstallRegistrySubkey)
}

function Assert-TestUninstallMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [Parameter(Mandatory = $true)][byte]$ExpectedMarker,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $uninstallRegistrySubkey, $false)
  if ($null -eq $key) { throw $Message }
  try {
    $version = [string]$key.GetValue('DisplayVersion', '')
    $binary = [byte[]]$key.GetValue('BinarySentinel', [byte[]]@())
    if ($version -cne $ExpectedVersion -or $binary.Length -ne 3 -or
        $binary[0] -ne $ExpectedMarker -or $binary[1] -ne 2 -or
        $binary[2] -ne 3) {
      throw $Message
    }
  } finally {
    $key.Close()
  }
}

function Assert-TestUninstallMetadataAbsent {
  param([Parameter(Mandatory = $true)][string]$Message)

  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $uninstallRegistrySubkey, $false)
  if ($null -ne $key) {
    $key.Close()
    throw $Message
  }
}

function Get-RecoveryArtifacts {
  $parent = [System.IO.Path]::GetDirectoryName($recoveryRoot)
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    return @()
  }
  $leaf = Split-Path -Path $recoveryRoot -Leaf
  return @(
    Get-ChildItem -LiteralPath $parent -Force |
      Where-Object {
        $_.Name -ieq $leaf -or $_.Name.StartsWith(
          "$leaf.cleanup.",
          [System.StringComparison]::OrdinalIgnoreCase
        )
      }
  )
}

function Assert-RecoveryPhase {
  param([Parameter(Mandatory = $true)][string]$ExpectedPhase)

  $artifacts = @(Get-RecoveryArtifacts)
  if ($artifacts.Count -eq 0) {
    throw "No durable $ExpectedPhase recovery artifact was retained."
  }
  foreach ($artifact in $artifacts) {
    $statePath = Join-Path $artifact.FullName 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
      continue
    }
    $state = Get-Content -LiteralPath $statePath -Encoding UTF8 -Raw |
      ConvertFrom-Json
    if ([string]$state.phase -ceq $ExpectedPhase) {
      return
    }
  }
  throw "No recovery artifact retained the $ExpectedPhase phase marker."
}

try {
  Set-TestUninstallMetadata -Version 'old-registry-version' -Marker 1
  Write-TestFile (Join-Path $installDir 'ssrvpn_windows.exe') 'old-launcher'
  Write-TestFile (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'old-app'
  Write-TestFile (Join-Path $installDir 'bin\data\app.so') 'old-data'
  Write-TestFile (Join-Path $installDir 'installer\stop.ps1') 'old-helper'
  Write-TestFile (Join-Path $installDir 'legacy\nested\obsolete.dll') `
    'obsolete-program-file'
  Write-TestFile $userDataPath 'user-owned-data'
  Write-TestFile $desktopShortcutPath 'old-desktop-shortcut'
  Write-TestFile $startMenuShortcutPath 'old-start-menu-shortcut'

  Invoke-Transaction -Action Begin
  Set-TestUninstallMetadata -Version 'interrupted-registry-version' -Marker 9
  Write-TestFile $desktopShortcutPath 'interrupted-desktop-shortcut'
  Write-TestFile $startMenuShortcutPath 'interrupted-start-menu-shortcut'
  $lockedPath = Join-Path $installDir 'bin\data\app.so'
  $lockedStream = New-Object System.IO.FileStream -ArgumentList @(
    $lockedPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
  Invoke-Transaction -Action Recover -ExpectFailure
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'old-launcher' `
    'intact current program changed during failed no-op recovery.'
  Assert-Text (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'old-app' `
    'intact current program changed during failed no-op recovery.'
  Assert-Text (Join-Path $installDir 'installer\stop.ps1') 'old-helper' `
    'intact current program changed during failed no-op recovery.'
  Assert-TestUninstallMetadata -ExpectedVersion `
    'interrupted-registry-version' -ExpectedMarker 9 `
    -Message 'failed recovery changed uninstall registry metadata.'
  $lockedStream.Dispose()
  $lockedStream = $null
  Invoke-Transaction -Action Recover
  Assert-TestUninstallMetadata -ExpectedVersion 'old-registry-version' `
    -ExpectedMarker 1 `
    -Message 'no-op recovery did not restore uninstall registry metadata.'
  Assert-Text $desktopShortcutPath 'old-desktop-shortcut' `
    'no-op recovery did not restore the desktop shortcut.'
  Assert-Text $startMenuShortcutPath 'old-start-menu-shortcut' `
    'no-op recovery did not restore the Start Menu shortcut.'
  if (@(Get-RecoveryArtifacts).Count -ne 0) {
    throw 'an intact current program did not finalize recovery as a no-op.'
  }

  $oversizedSourceRoot = Join-Path $installDir 'oversized-depth'
  $oversizedSourcePath = $oversizedSourceRoot
  for ($depth = 0; $depth -lt 65; $depth++) {
    $oversizedSourcePath = Join-Path $oversizedSourcePath 'd'
  }
  Write-TestFile (Join-Path $oversizedSourcePath 'sentinel.bin') 'bounded'
  Invoke-Transaction -Action Begin -ExpectFailure
  if (Test-Path -LiteralPath $recoveryRoot) {
    throw 'oversized source was copied into recovery.'
  }
  Assert-Text $userDataPath 'user-owned-data' `
    'oversized source inventory changed bin\ssrvpn user data.'
  Remove-Item -LiteralPath $oversizedSourceRoot -Recurse -Force

  Invoke-Transaction -Action Begin
  $statePath = Join-Path $recoveryRoot 'state.json'
  $validStateBytes = [System.IO.File]::ReadAllBytes($statePath)
  $oversizedStateBytes = New-Object byte[] (8MB + 1)
  [System.IO.File]::WriteAllBytes($statePath, $oversizedStateBytes)
  Invoke-Transaction -Action Recover -ExpectFailure
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'old-launcher' `
    'oversized recovery state changed the installed program.'
  Assert-Text $userDataPath 'user-owned-data' `
    'oversized recovery state changed bin\ssrvpn user data.'
  [System.IO.File]::WriteAllBytes($statePath, $validStateBytes)

  $manifestPath = Join-Path $recoveryRoot 'manifest.json'
  $validManifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
  $invalidManifest = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw |
    ConvertFrom-Json
  $invalidManifest | Add-Member -NotePropertyName unexpected `
    -NotePropertyValue $true
  Write-TestFile $manifestPath ($invalidManifest | ConvertTo-Json -Depth 8)
  Invoke-Transaction -Action Recover -ExpectFailure
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'old-launcher' `
    'invalid manifest schema changed the installed program.'
  Assert-Text $userDataPath 'user-owned-data' `
    'invalid manifest schema changed bin\ssrvpn user data.'
  [System.IO.File]::WriteAllBytes($manifestPath, $validManifestBytes)
  Invoke-Transaction -Action Recover

  Invoke-Transaction -Action Begin
  Write-ExpectedPayloadManifest
  Remove-Item -LiteralPath $recoveryRoot -Recurse -Force
  Invoke-Transaction -Action Commit -ExpectFailure
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'old-launcher' `
    'missing recovery transaction unexpectedly committed or changed the program.'

  Invoke-Transaction -Action Begin
  if (Test-Path -LiteralPath (
      Join-Path $recoveryRoot 'program\bin\ssrvpn')) {
    throw 'bin\ssrvpn user data entered the program-file backup.'
  }

  $backedUpAppPath = Join-Path $recoveryRoot `
    'program\bin\ssrvpn_windows_app.exe'
  Write-TestFile $backedUpAppPath 'tampered-backup'
  Invoke-Transaction -Action Recover -ExpectFailure
  Assert-Text (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'old-app' `
    'tampered backup changed the current program before verification.'
  Assert-Text $userDataPath 'user-owned-data' `
    'tampered backup changed bin\ssrvpn user data.'
  Write-TestFile $backedUpAppPath 'old-app'

  Remove-Item -LiteralPath (Join-Path $installDir 'ssrvpn_windows.exe') -Force
  Write-TestFile (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'partial-app'
  Write-TestFile (Join-Path $installDir 'partial-new.dll') 'partial-new'
  $lockedPath = Join-Path $installDir 'partial-locked.dll'
  Write-TestFile $lockedPath 'locked-partial'
  $lockedStream = New-Object System.IO.FileStream -ArgumentList @(
    $lockedPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )

  Invoke-Transaction -Action Recover -ExpectFailure
  if (-not (Test-Path -LiteralPath $recoveryRoot -PathType Container)) {
    throw 'failed recovery discarded the only program-file backup.'
  }
  Assert-Text $userDataPath 'user-owned-data' `
    'failed recovery changed bin\ssrvpn user data.'
  $lockedStream.Dispose()
  $lockedStream = $null

  Invoke-Transaction -Action Recover
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'old-launcher' `
    'launcher was not restored after an interrupted overwrite.'
  Assert-Text (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'old-app' `
    'application binary was not restored after an interrupted overwrite.'
  Assert-Text (Join-Path $installDir 'bin\data\app.so') 'old-data' `
    'Flutter program data was not restored after an interrupted overwrite.'
  Assert-Text $userDataPath 'user-owned-data' `
    'successful recovery changed bin\ssrvpn user data.'
  if (Test-Path -LiteralPath (Join-Path $installDir 'partial-new.dll')) {
    throw 'unverified partial program file survived recovery.'
  }
  if (Test-Path -LiteralPath $recoveryRoot) {
    throw 'successful recovery left the transaction directory behind.'
  }

  Invoke-Transaction -Action Begin
  Write-TestFile (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') `
    'interrupted-app'
  $cleanupLockPath = Join-Path $recoveryRoot 'zzz-cleanup-lock'
  Write-TestFile $cleanupLockPath 'locked-cleanup'
  $lockedStream = New-Object System.IO.FileStream -ArgumentList @(
    $cleanupLockPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
  Invoke-Transaction -Action Recover -ExpectFailure
  Assert-Text (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'old-app' `
    'recovery cleanup fault did not restore the old application first.'
  Assert-RecoveryPhase -ExpectedPhase 'restored'
  $lockedStream.Dispose()
  $lockedStream = $null
  Invoke-Transaction -Action Recover
  if (@(Get-RecoveryArtifacts).Count -ne 0) {
    throw 'retry left a finalized recovery artifact behind.'
  }

  Invoke-Transaction -Action Begin
  Invoke-Transaction -Action Clear
  if (Test-Path -LiteralPath (
      Join-Path $installDir 'legacy\nested\obsolete.dll')) {
    throw 'stale nested program file survived transactional clear.'
  }
  Assert-Text $userDataPath 'user-owned-data' `
    'transactional clear changed bin\ssrvpn user data.'
  Write-TestFile (Join-Path $installDir 'ssrvpn_windows.exe') 'new-launcher'
  Write-TestFile (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'new-app'
  Write-TestFile (Join-Path $installDir 'bin\required-plugin.dll') 'new-plugin'
  Write-ExpectedPayloadManifest
  Write-TestFile (Join-Path $installDir 'bin\required-plugin.dll') 'stale-plugin'
  Invoke-Transaction -Action Validate -ExpectFailure
  Assert-RecoveryPhase -ExpectedPhase 'cleared'
  Assert-Text (Join-Path $installDir 'bin\required-plugin.dll') 'stale-plugin' `
    'payload mismatch unexpectedly committed or changed the new payload.'
  Write-TestFile (Join-Path $installDir 'bin\required-plugin.dll') 'new-plugin'
  $unexpectedPayloadPath = Join-Path $installDir 'bin\unexpected-plugin.dll'
  Write-TestFile $unexpectedPayloadPath 'unexpected-plugin'
  Invoke-Transaction -Action Validate -ExpectFailure
  Assert-RecoveryPhase -ExpectedPhase 'cleared'
  Remove-Item -LiteralPath $unexpectedPayloadPath -Force
  Invoke-Transaction -Action Commit -ExpectFailure
  try {
    Assert-RecoveryPhase -ExpectedPhase 'cleared'
  } catch {
    throw "unvalidated payload unexpectedly committed: $($_.Exception.Message)"
  }
  Write-ExpectedPayloadManifest -UppercasePaths
  try {
    Invoke-Transaction -Action Validate
  } catch {
    throw (
      'payload path casing unexpectedly failed validation: ' +
      $_.Exception.Message)
  }
  Assert-RecoveryPhase -ExpectedPhase 'validated'
  Set-TestUninstallMetadata -Version 'new-registry-version' -Marker 7
  Write-TestFile $desktopShortcutPath 'new-desktop-shortcut'
  Write-TestFile $startMenuShortcutPath 'new-start-menu-shortcut'
  $committedBackupPath = Join-Path $recoveryRoot `
    'program\ssrvpn_windows.exe'
  $lockedStream = New-Object System.IO.FileStream -ArgumentList @(
    $committedBackupPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::None
  )
  Invoke-Transaction -Action Commit
  Assert-RecoveryPhase -ExpectedPhase 'committed'
  $lockedStream.Dispose()
  $lockedStream = $null
  Invoke-Transaction -Action Recover
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'new-launcher' `
    'startup recovery rolled back a committed install.'
  Assert-Text (Join-Path $installDir 'bin\ssrvpn_windows_app.exe') 'new-app' `
    'committed application binary was rolled back.'
  Assert-Text $userDataPath 'user-owned-data' `
    'successful commit changed user data.'
  Assert-TestUninstallMetadata -ExpectedVersion 'new-registry-version' `
    -ExpectedMarker 7 `
    -Message 'successful commit changed new uninstall registry metadata.'
  Assert-Text $desktopShortcutPath 'new-desktop-shortcut' `
    'successful commit changed the new desktop shortcut.'
  Assert-Text $startMenuShortcutPath 'new-start-menu-shortcut' `
    'successful commit changed the new Start Menu shortcut.'
  if (@(Get-RecoveryArtifacts).Count -ne 0) {
    throw 'successful commit left the transaction directory behind.'
  }

  Invoke-Transaction -Action Begin
  $discardLockPath = Join-Path $recoveryRoot `
    'program\ssrvpn_windows.exe'
  $lockedStream = New-Object System.IO.FileStream -ArgumentList @(
    $discardLockPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::None
  )
  Invoke-Transaction -Action Discard -ExpectFailure
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'new-launcher' `
    'failed discard changed the installed launcher.'
  Assert-Text $userDataPath 'user-owned-data' `
    'failed discard changed bin\ssrvpn user data.'
  $lockedStream.Dispose()
  $lockedStream = $null
  Invoke-Transaction -Action Discard
  if (@(Get-RecoveryArtifacts).Count -ne 0) {
    throw 'discard left program-file recovery artifacts behind.'
  }
  Assert-Text (Join-Path $installDir 'ssrvpn_windows.exe') 'new-launcher' `
    'discard changed the installed launcher.'
  Assert-Text $userDataPath 'user-owned-data' `
    'discard changed bin\ssrvpn user data.'

  Remove-Item -LiteralPath $installDir -Recurse -Force
  Remove-TestUninstallMetadata
  Remove-Item -LiteralPath $desktopShortcutPath -Force
  Remove-Item -LiteralPath $startMenuShortcutPath -Force
  Invoke-Transaction -Action Begin
  Invoke-Transaction -Action Clear
  if (-not (Test-Path -LiteralPath $recoveryRoot -PathType Container)) {
    throw 'a clean install did not create a rollback transaction.'
  }
  Write-TestFile (Join-Path $installDir 'partial-first-install.dll') 'partial'
  Set-TestUninstallMetadata -Version 'partial-clean-install' -Marker 5
  Write-TestFile $desktopShortcutPath 'partial-desktop-shortcut'
  Write-TestFile $startMenuShortcutPath 'partial-start-menu-shortcut'
  Invoke-Transaction -Action Recover
  if (Test-Path -LiteralPath (
      Join-Path $installDir 'partial-first-install.dll')) {
    throw 'clean-install recovery left a partial program file behind.'
  }
  if (Test-Path -LiteralPath $recoveryRoot) {
    throw 'clean-install recovery left the transaction directory behind.'
  }
  Assert-TestUninstallMetadataAbsent `
    -Message 'clean-install recovery left uninstall metadata behind.'
  if ((Test-Path -LiteralPath $desktopShortcutPath) -or
      (Test-Path -LiteralPath $startMenuShortcutPath)) {
    throw 'clean-install recovery left shortcut metadata behind.'
  }
} finally {
  if ($null -ne $lockedStream) {
    $lockedStream.Dispose()
  }
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
  Remove-TestUninstallMetadata
}

Write-Host 'Windows program-file transaction fault injection passed.'
