[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Destination,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$StateFile,
  [string]$SetupSource = '',
  [switch]$DiscoverOnly
)

$ErrorActionPreference = 'Stop'

function Test-PortableDataDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
      return $false
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      return $false
    }
    foreach ($name in @('settings.json', 'subscriptions.json')) {
      if (Test-Path -LiteralPath (Join-Path $Path $name) -PathType Leaf) {
        return $true
      }
    }
  } catch {
    return $false
  }
  return $false
}

function Add-PortableSource {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Table,
    [Parameter(Mandatory = $true)][string]$Path
  )

  if (-not (Test-PortableDataDirectory -Path $Path)) { return }
  $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
  $Table[$fullPath.ToLowerInvariant()] = $fullPath
}

function Test-IsDestination {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  return $Path.Equals(
    $DestinationPath,
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

$destinationPath = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
$statePath = [System.IO.Path]::GetFullPath($StateFile)

if ($DiscoverOnly) {
  $sources = @{}
  $runningSources = @{}
  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue

  try {
    $runningProcesses = @(Get-CimInstance -ClassName Win32_Process `
      -Filter "Name = 'ssrvpn_windows_app.exe'" -ErrorAction Stop)
  } catch {
    $runningProcesses = @()
    [Console]::Error.WriteLine(
      "Portable process discovery unavailable; using filesystem scan: $($_.Exception.Message)"
    )
  }
  $runningProcesses |
    Where-Object { $_.ExecutablePath } |
    ForEach-Object {
      Add-PortableSource -Table $runningSources -Path (Join-Path `
        (Split-Path -LiteralPath $_.ExecutablePath -Parent) 'ssrvpn')
    }

  $userProfile = [Environment]::GetFolderPath('UserProfile')
  $downloads = if ($userProfile) { Join-Path $userProfile 'Downloads' } else { $null }
  $roots = @(
    $SetupSource,
    [Environment]::GetFolderPath('Desktop'),
    $downloads
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }

  foreach ($root in $roots) {
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue(@{ Path = $root; Depth = 0 })
    while ($queue.Count -gt 0) {
      $entry = $queue.Dequeue()
      $directory = [string]$entry.Path
      foreach ($layout in @(
        @{ App = 'ssrvpn_windows_app.exe'; Data = 'ssrvpn' },
        @{ App = 'bin\ssrvpn_windows_app.exe'; Data = 'bin\ssrvpn' }
      )) {
        if (Test-Path -LiteralPath (Join-Path $directory $layout.App) -PathType Leaf) {
          Add-PortableSource -Table $sources -Path `
            (Join-Path $directory $layout.Data)
        }
      }
      if ([int]$entry.Depth -ge 2) { continue }
      Get-ChildItem -LiteralPath $directory -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
          $queue.Enqueue(@{ Path = $_.FullName; Depth = [int]$entry.Depth + 1 })
        }
    }
  }

  $runningCandidates = @($runningSources.Values | Where-Object {
    -not (Test-IsDestination -Path $_ -DestinationPath $destinationPath)
  })
  $candidates = @($sources.Values | Where-Object {
    -not (Test-IsDestination -Path $_ -DestinationPath $destinationPath)
  })

  if ($runningCandidates.Count -gt 1) {
    [Console]::Error.WriteLine(
      'Multiple running portable SSRVPN data directories were found.'
    )
    exit 10
  }
  if ($runningCandidates.Count -eq 1) {
    $sourcePath = [string]$runningCandidates[0]
  } elseif ($candidates.Count -gt 1) {
    [Console]::Error.WriteLine(
      'Multiple portable SSRVPN data directories were found.'
    )
    exit 10
  } elseif ($candidates.Count -eq 1) {
    $sourcePath = [string]$candidates[0]
  } else {
    $sourcePath = $null
  }

  if ($sourcePath) {
    $stateDirectory = Split-Path -LiteralPath $statePath -Parent
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $tempState = "$statePath.tmp"
    [System.IO.File]::WriteAllText($tempState, $sourcePath)
    Move-Item -LiteralPath $tempState -Destination $statePath -Force
  }
  return
}

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
$sourcePath = (Get-Content -LiteralPath $statePath -Raw).Trim()
if (-not $sourcePath -or
    (Test-IsDestination -Path $sourcePath -DestinationPath $destinationPath) -or
    -not (Test-PortableDataDirectory -Path $sourcePath)) {
  throw 'The selected portable SSRVPN data directory is no longer valid.'
}

New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
foreach ($name in @(
  'settings.json',
  'subscriptions.json',
  'subscription_cache.yaml',
  'config.yaml',
  'country.mmdb',
  'geoip.metadb'
)) {
  $sourceFile = Join-Path $sourcePath $name
  $destinationFile = Join-Path $destinationPath $name
  if (
    (Test-Path -LiteralPath $sourceFile -PathType Leaf) -and
    -not (Test-Path -LiteralPath $destinationFile)
  ) {
    $tempFile = "$destinationFile.$PID.tmp"
    try {
      Copy-Item -LiteralPath $sourceFile -Destination $tempFile -Force
      $sourceItem = Get-Item -LiteralPath $sourceFile
      $tempItem = Get-Item -LiteralPath $tempFile
      if ($sourceItem.Length -ne $tempItem.Length) {
        throw "Portable data length verification failed for $name."
      }
      $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
      $tempHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash
      if ($sourceHash -ne $tempHash) {
        throw "Portable data hash verification failed for $name."
      }
      Move-Item -LiteralPath $tempFile -Destination $destinationFile
    } finally {
      Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
  }
}

Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
