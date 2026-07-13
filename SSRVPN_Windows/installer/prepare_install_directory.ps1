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

function Copy-VerifiedFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
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
  $backupPath = [System.IO.Path]::GetFullPath([string]$state.dataBackup)
  if (-not (Test-ChildPath -Parent $recoveryPath -Child $backupPath)) {
    throw 'The recorded SSRVPN recovery directory is outside the recovery root.'
  }
  if (Test-ReparsePoint -Path $backupPath) {
    throw 'The recorded SSRVPN recovery directory is a reparse point.'
  }

  New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
  foreach ($name in $dataFiles) {
    $source = Join-Path $backupPath $name
    $destination = Join-Path $dataPath $name
    if ((Test-Path -LiteralPath $source -PathType Leaf) -and
        -not (Test-ReparsePoint -Path $source) -and
        -not (Test-Path -LiteralPath $destination)) {
      Copy-VerifiedFile -Source $source -Destination $destination
    }
  }

  $backupRoot = [System.IO.Path]::GetFullPath([string]$state.backupRoot)
  if (Test-ChildPath -Parent $recoveryPath -Child $backupRoot) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force `
      -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
}

if ($Restore) {
  Restore-RebuildData
  return
}

# Finish a recoverable prior attempt before evaluating the current directory.
try {
  Restore-RebuildData
} catch {
  Write-Warning "Prior SSRVPN recovery state could not be reused: $($_.Exception.Message)"
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $invalidState = "$statePath.invalid-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))"
    Move-Item -LiteralPath $statePath -Destination $invalidState -Force `
      -ErrorAction SilentlyContinue
  }
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

if ((Test-Path -LiteralPath $dataPath -PathType Container) -and
    -not (Test-ReparsePoint -Path $dataPath)) {
  foreach ($name in $dataFiles) {
    $source = Join-Path $dataPath $name
    if ((Test-Path -LiteralPath $source -PathType Leaf) -and
        -not (Test-ReparsePoint -Path $source)) {
      Copy-VerifiedFile -Source $source -Destination (Join-Path $dataBackup $name)
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
}
$tempState = "$statePath.$PID.tmp"
try {
  [System.IO.File]::WriteAllText(
    $tempState,
    ($state | ConvertTo-Json -Compress),
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
