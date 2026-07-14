[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$InstallDir,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$DataDir,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RecoveryRoot,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$StateFile,
  [switch]$Restore,
  [switch]$ForceRebuild
)

$ErrorActionPreference = 'Stop'
$dataFiles = @(
  '.api-secret.dpapi',
  'settings.json',
  'subscriptions.json',
  'subscription_cache.yaml',
  'config.yaml',
  'country.mmdb',
  'geoip.metadb'
)

function Test-ChildPath {
  param(
    [Parameter(Mandatory = $true)][string]$Parent,
    [Parameter(Mandatory = $true)][string]$Child
  )

  $parentPrefix = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  $childPath = [System.IO.Path]::GetFullPath($Child)
  return $childPath.StartsWith(
    $parentPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Test-ReparsePoint {
  param([Parameter(Mandatory = $true)][string]$Path)

  $item = Get-PathItem -Path $Path
  if ($null -eq $item) { return $false }
  return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-PathItem {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  } catch {
    return $null
  }
}

function Test-DirectoryWritable {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if (Test-ReparsePoint -Path $Path) { return $false }
    $probe = Join-Path $Path ".ssrvpn-installer-write-$PID.tmp"
    [System.IO.File]::WriteAllText($probe, 'ok')
    Remove-Item -LiteralPath $probe -Force
    return $true
  } catch {
    return $false
  }
}

function Test-ActiveUserDataPresent {
  foreach ($name in @(
      '.api-secret.dpapi',
      'settings.json',
      'subscriptions.json',
      'subscription_cache.yaml',
      'config.yaml'
    )) {
    $item = Get-PathItem -Path (Join-Path $dataPath $name)
    if ($null -ne $item -and -not $item.PSIsContainer -and
        -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      return $true
    }
  }
  return $false
}

function Copy-VerifiedFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$ExpectedHash = ''
  )

  $destinationParent = Split-Path -LiteralPath $Destination -Parent
  New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  $temp = "$Destination.$PID.tmp"
  try {
    Copy-Item -LiteralPath $Source -Destination $temp -Force
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $tempHash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    if ($sourceHash -ne $tempHash) {
      throw "Backup hash mismatch for $Source."
    }
    if ($ExpectedHash -and -not $tempHash.Equals(
        $ExpectedHash,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
      throw "Copied file hash differs from the recovery manifest: $Source"
    }
    Move-Item -LiteralPath $temp -Destination $Destination -Force
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

$installPath = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$dataPath = [System.IO.Path]::GetFullPath($DataDir).TrimEnd('\')
$recoveryPath = [System.IO.Path]::GetFullPath($RecoveryRoot).TrimEnd('\')
$statePath = [System.IO.Path]::GetFullPath($StateFile)

if (-not (Test-ChildPath -Parent $installPath -Child $dataPath)) {
  throw 'The SSRVPN data directory is outside the active installation directory.'
}
if ((Test-ChildPath -Parent $installPath -Child $recoveryPath) -or
    $installPath.Equals(
      $recoveryPath,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
  throw 'The recovery directory must be outside the active installation directory.'
}

function Restore-RebuildData {
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }

  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if (-not ($state.PSObject.Properties.Name -contains 'files')) {
    throw 'The SSRVPN recovery manifest is missing.'
  }
  $recordedInstallPath = [System.IO.Path]::GetFullPath(
    [string]$state.installDir
  ).TrimEnd('\')
  $recordedDataPath = [System.IO.Path]::GetFullPath(
    [string]$state.dataDir
  ).TrimEnd('\')
  if (-not $recordedInstallPath.Equals(
      $installPath,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or -not $recordedDataPath.Equals(
      $dataPath,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The SSRVPN recovery state belongs to a different installation.'
  }
  $backupRoot = [System.IO.Path]::GetFullPath([string]$state.backupRoot)
  $backupPath = [System.IO.Path]::GetFullPath([string]$state.dataBackup)
  if (-not (Test-ChildPath -Parent $recoveryPath -Child $backupRoot) -or
      -not (Test-ChildPath -Parent $backupRoot -Child $backupPath)) {
    throw 'The recorded SSRVPN recovery directory is outside the recovery root.'
  }
  if (-not (Test-Path -LiteralPath $backupRoot -PathType Container) -or
      -not (Test-Path -LiteralPath $backupPath -PathType Container)) {
    throw 'The recorded SSRVPN recovery directory is missing.'
  }
  if ((Test-ReparsePoint -Path $backupRoot) -or
      (Test-ReparsePoint -Path $backupPath)) {
    throw 'The recorded SSRVPN recovery directory is a reparse point.'
  }

  # Verify the complete manifest before touching the new installation. A
  # missing or modified backup must retain the state and archived app so the
  # failure stays recoverable.
  $manifest = @($state.files)
  $seenNames = @{}
  foreach ($entry in $manifest) {
    $name = [string]$entry.name
    $expectedHash = [string]$entry.sha256
    if (-not ($dataFiles -contains $name) -or $seenNames.ContainsKey($name)) {
      throw "The SSRVPN recovery manifest contains an invalid file: $name"
    }
    if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
      throw "The SSRVPN recovery manifest contains an invalid hash: $name"
    }
    $seenNames[$name] = $true
    $source = Join-Path $backupPath $name
    $sourceItem = Get-PathItem -Path $source
    if ($null -eq $sourceItem -or $sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      throw "Recovery source is missing or not a regular file: $source"
    }
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if (-not $sourceHash.Equals(
        $expectedHash,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
      throw "Recovery source hash differs from the manifest: $source"
    }
  }

  New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
  foreach ($entry in $manifest) {
    $name = [string]$entry.name
    $expectedHash = [string]$entry.sha256
    $source = Join-Path $backupPath $name
    $destination = Join-Path $dataPath $name

    $destinationItem = Get-PathItem -Path $destination
    if ($null -eq $destinationItem) {
      Copy-VerifiedFile -Source $source -Destination $destination `
        -ExpectedHash $expectedHash
      continue
    }
    if ($destinationItem.PSIsContainer -or
        ($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      throw "Recovery destination is not a regular file: $destination"
    }
    $destinationHash = (
      Get-FileHash -LiteralPath $destination -Algorithm SHA256
    ).Hash
    if (-not $destinationHash.Equals(
        $expectedHash,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
      throw "Recovery conflict; preserved backup differs from $destination"
    }
  }

  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Remove-Item -LiteralPath $statePath -Force
}

if ($Restore) {
  Restore-RebuildData
  return
}

# A complete writable installation with current user data is authoritative.
# Do not let stale recovery metadata from an older failed installer attempt
# permanently block an ordinary in-place upgrade. The old evidence remains on
# disk and is reconsidered if the active installation ever needs rebuilding.
if ((Test-Path -LiteralPath $installPath -PathType Container) -and
    -not (Test-ReparsePoint -Path $installPath) -and
    -not $ForceRebuild -and
    (Test-DirectoryWritable -Path $installPath) -and
    (Test-ActiveUserDataPresent)) {
  return
}

# Finish a recoverable prior attempt before evaluating the current directory.
try {
  Restore-RebuildData
} catch {
  throw "Prior SSRVPN recovery must be resolved before installation: $($_.Exception.Message)"
}

if ((Test-Path -LiteralPath $installPath -PathType Container) -and
    -not (Test-ReparsePoint -Path $installPath) -and
    -not $ForceRebuild -and
    (Test-DirectoryWritable -Path $installPath)) {
  return
}

$backupRoot = Join-Path $recoveryPath (
  "rebuild-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-" +
  [Guid]::NewGuid().ToString('N')
)
$dataBackup = Join-Path $backupRoot 'data'
New-Item -ItemType Directory -Path $dataBackup -Force | Out-Null
$backupManifest = @()

if ((Test-Path -LiteralPath $dataPath -PathType Container) -and
    -not (Test-ReparsePoint -Path $dataPath)) {
  foreach ($name in $dataFiles) {
    $source = Join-Path $dataPath $name
    $sourceItem = Get-PathItem -Path $source
    if ($null -eq $sourceItem) { continue }
    if ($sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      throw "SSRVPN data source is not a regular file: $source"
    }
    $destination = Join-Path $dataBackup $name
    Copy-VerifiedFile -Source $source -Destination $destination
    $backupManifest += [ordered]@{
      name = $name
      sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
  }
}

$stateParent = Split-Path -LiteralPath $statePath -Parent
New-Item -ItemType Directory -Path $stateParent -Force | Out-Null
$state = [ordered]@{
  installDir = $installPath
  dataDir = $dataPath
  backupRoot = $backupRoot
  dataBackup = $dataBackup
  files = $backupManifest
}
$tempState = "$statePath.$PID.tmp"
try {
  [System.IO.File]::WriteAllText(
    $tempState,
    ($state | ConvertTo-Json -Depth 4 -Compress),
    (New-Object System.Text.UTF8Encoding($false))
  )
  Move-Item -LiteralPath $tempState -Destination $statePath -Force
} finally {
  Remove-Item -LiteralPath $tempState -Force -ErrorAction SilentlyContinue
}

if ($null -ne (Get-PathItem -Path $installPath)) {
  $archivedApp = Join-Path $backupRoot 'app'
  try {
    Move-Item -LiteralPath $installPath -Destination $archivedApp -Force
  } catch {
    # The verified data backup is already outside the install tree. A recursive
    # removal is therefore safe and gives a damaged directory one last recovery
    # path before Inno Setup copies the new version.
    $installItem = Get-PathItem -Path $installPath
    if ($null -ne $installItem -and
        ($installItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      if ($installItem.PSIsContainer) {
        [System.IO.Directory]::Delete($installPath, $false)
      } else {
        [System.IO.File]::Delete($installPath)
      }
    } else {
      Remove-Item -LiteralPath $installPath -Recurse -Force
    }
  }
}
New-Item -ItemType Directory -Path $installPath -Force | Out-Null
if (-not (Test-DirectoryWritable -Path $installPath)) {
  throw "The active SSRVPN installation directory is still not writable: $installPath"
}

# Inno Setup uses this successful non-zero code to remember that post-install
# data restoration is required. Other non-zero codes remain real failures.
exit 10
