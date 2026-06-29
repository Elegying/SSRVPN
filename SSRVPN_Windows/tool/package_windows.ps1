[CmdletBinding()]
param(
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot '..')
)
$buildDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$releaseDir = Join-Path $projectRoot 'SSRVPN_Windows_Release'
$zipPath = Join-Path $projectRoot 'SSRVPN.zip'
$zipHashPath = "$zipPath.sha256"

$requiredFiles = @(
  'ssrvpn_windows.exe',
  'ssrvpn_safe_mode.bat',
  'SAFE_MODE_README.txt',
  'mihomo.exe',
  'flutter_windows.dll',
  'screen_retriever_windows_plugin.dll',
  'system_tray_plugin.dll',
  'window_manager_plugin.dll',
  'concrt140.dll',
  'msvcp140.dll',
  'msvcp140_1.dll',
  'msvcp140_2.dll',
  'msvcp140_atomic_wait.dll',
  'msvcp140_codecvt_ids.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
  'data\app.so',
  'data\icudtl.dat',
  'data\flutter_assets\assets\geoip.metadb.gz',
  'data\flutter_assets\assets\icon.ico'
)

function Test-ReleaseContents {
  param([Parameter(Mandatory = $true)][string]$Root)

  foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required release file is missing: $relativePath"
    }
    if ((Get-Item -LiteralPath $path).Length -le 0) {
      throw "Required release file is empty: $relativePath"
    }
  }

  $core = Join-Path $Root 'mihomo.exe'
  $coreOutput = & $core -v 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Bundled Mihomo failed to execute: $coreOutput"
  }
  if (($coreOutput | Out-String) -notmatch 'Mihomo Meta') {
    throw "Bundled Mihomo returned an unexpected version response: $coreOutput"
  }
}

function Test-ReleaseHashes {
  param([Parameter(Mandatory = $true)][string]$Root)

  $hashFile = Join-Path $Root 'SHA256SUMS.txt'
  if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
    throw "Release hash manifest is missing: $hashFile"
  }

  foreach ($line in Get-Content -LiteralPath $hashFile -Encoding UTF8) {
    if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') {
      throw "Invalid SHA256SUMS line: $line"
    }
    $expectedHash = $matches[1].ToUpperInvariant()
    $relativePath = $matches[2]
    $file = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
      throw "Hashed release file is missing: $relativePath"
    }
    $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
      throw "Release hash mismatch: $relativePath"
    }
  }
}

function Repair-WindowsPluginLinks {
  param([Parameter(Mandatory = $true)][string]$Root)

  $dependenciesPath = Join-Path $Root '.flutter-plugins-dependencies'
  if (-not (Test-Path -LiteralPath $dependenciesPath -PathType Leaf)) {
    throw "Flutter plugin metadata not found: $dependenciesPath"
  }

  $metadata = Get-Content -LiteralPath $dependenciesPath -Raw |
    ConvertFrom-Json
  $plugins = @($metadata.plugins.windows)
  $linksDir = [System.IO.Path]::GetFullPath(
    (Join-Path $Root 'windows\flutter\ephemeral\.plugin_symlinks')
  )
  $expectedLinksDir = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks')
  )
  if ($linksDir -ne $expectedLinksDir) {
    throw "Refusing to replace unexpected plugin directory: $linksDir"
  }

  if (Test-Path -LiteralPath $linksDir) {
    Remove-Item -LiteralPath $linksDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $linksDir | Out-Null

  foreach ($plugin in $plugins) {
    $linkPath = Join-Path $linksDir $plugin.name
    $targetPath = $plugin.path.TrimEnd('\')
    try {
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath `
        -ErrorAction Stop | Out-Null
    } catch [System.UnauthorizedAccessException] {
      New-Item -ItemType Junction -Path $linkPath -Target $targetPath `
        -ErrorAction Stop | Out-Null
    }
  }
}

Push-Location $projectRoot
try {
  if (-not $SkipBuild) {
    $previousParallelLevel = $env:CMAKE_BUILD_PARALLEL_LEVEL
    $lockPath = Join-Path $projectRoot 'pubspec.lock'
    $lockExisted = Test-Path -LiteralPath $lockPath -PathType Leaf
    [byte[]]$lockBytes = $null
    if ($lockExisted) {
      $lockBytes = [System.IO.File]::ReadAllBytes($lockPath)
    }
    try {
      # New MSVC toolsets occasionally fail in STL headers under highly
      # parallel Flutter builds. A single build worker favors reproducibility.
      $env:CMAKE_BUILD_PARALLEL_LEVEL = '1'
      & flutter pub get
      if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed with exit code $LASTEXITCODE"
      }
      Repair-WindowsPluginLinks -Root $projectRoot
      & flutter build windows --release --no-pub
      if ($LASTEXITCODE -ne 0) {
        throw "flutter build failed with exit code $LASTEXITCODE"
      }
    } finally {
      $env:CMAKE_BUILD_PARALLEL_LEVEL = $previousParallelLevel
      if ($lockExisted) {
        [System.IO.File]::WriteAllBytes($lockPath, $lockBytes)
      } elseif (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force
      }
    }
  }

  if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) {
    throw "Release build directory not found: $buildDir"
  }

  $expectedReleaseDir = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot 'SSRVPN_Windows_Release')
  )
  if ([System.IO.Path]::GetFullPath($releaseDir) -ne $expectedReleaseDir) {
    throw "Refusing to clean unexpected release directory: $releaseDir"
  }

  if (Test-Path -LiteralPath $releaseDir) {
    Remove-Item -LiteralPath $releaseDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $releaseDir | Out-Null
  Copy-Item -Path (Join-Path $buildDir '*') -Destination $releaseDir `
    -Recurse -Force
  $portableReadmeName = [string]::Concat(
    [char]0x4F7F,
    [char]0x7528,
    [char]0x6559,
    [char]0x7A0B,
    '.txt'
  )
  Copy-Item -LiteralPath (Join-Path $projectRoot 'PORTABLE_README.txt') `
    -Destination (Join-Path $releaseDir $portableReadmeName)

  Test-ReleaseContents -Root $releaseDir

  $releasePrefix = [System.IO.Path]::GetFullPath($releaseDir).TrimEnd('\') + '\'
  $hashLines = Get-ChildItem -LiteralPath $releaseDir -Recurse -File |
    Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object FullName |
    ForEach-Object {
      $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
      $fullName = [System.IO.Path]::GetFullPath($_.FullName)
      if (-not $fullName.StartsWith(
        $releasePrefix,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
        throw "Release file is outside the expected directory: $fullName"
      }
      $relativePath = $fullName.Substring($releasePrefix.Length)
      "$($hash.Hash)  $relativePath"
    }
  $hashLines | Set-Content -LiteralPath (
    Join-Path $releaseDir 'SHA256SUMS.txt'
  ) -Encoding UTF8
  Test-ReleaseHashes -Root $releaseDir

  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  if (Test-Path -LiteralPath $zipHashPath) {
    Remove-Item -LiteralPath $zipHashPath -Force
  }
  Compress-Archive -LiteralPath $releaseDir -DestinationPath $zipPath `
    -CompressionLevel Optimal

  $verifyRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
  ) "SSRVPN-package-verify-$([Guid]::NewGuid().ToString('N'))"
  try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $verifyRoot
    $verifiedReleaseDir = Join-Path $verifyRoot 'SSRVPN_Windows_Release'
    Test-ReleaseContents -Root $verifiedReleaseDir
    Test-ReleaseHashes -Root $verifiedReleaseDir
  } finally {
    $expectedTempRoot = [System.IO.Path]::GetFullPath(
      [System.IO.Path]::GetTempPath()
    )
    $resolvedVerifyRoot = [System.IO.Path]::GetFullPath($verifyRoot)
    if (-not $resolvedVerifyRoot.StartsWith(
      $expectedTempRoot,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
      throw "Refusing to clean unexpected verification directory: $verifyRoot"
    }
    if (Test-Path -LiteralPath $resolvedVerifyRoot) {
      Remove-Item -LiteralPath $resolvedVerifyRoot -Recurse -Force
    }
  }

  $zipHash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
  "$($zipHash.Hash)  $([System.IO.Path]::GetFileName($zipPath))" |
    Set-Content -LiteralPath $zipHashPath -Encoding ASCII
  Write-Host "Release: $releaseDir"
  Write-Host "ZIP:     $zipPath"
  Write-Host "ZIP hash:$zipHashPath"
  Write-Host "SHA256:  $($zipHash.Hash)"
} finally {
  Pop-Location
}
