[CmdletBinding()]
param(
  [string]$SourceDir,
  [string]$OutputDir,
  [string]$Version,
  [string]$InnoCompiler
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

if (-not $SourceDir) {
  $SourceDir = Join-Path $projectRoot 'SSRVPN_Windows_Release'
}
if (-not $OutputDir) {
  $OutputDir = $projectRoot
}
$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

if (-not $Version) {
  $pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
  foreach ($line in Get-Content -LiteralPath $pubspecPath -Encoding UTF8) {
    if ($line -match '^version:\s*([^+\s]+)') {
      $Version = $matches[1]
      break
    }
  }
}
if (-not $Version -or $Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
  throw "Invalid installer version: $Version"
}

foreach ($relativePath in @('ssrvpn_windows.exe', 'bin\ssrvpn_windows_app.exe')) {
  $path = Join-Path $SourceDir $relativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Installer source is missing $relativePath`: $SourceDir"
  }
}
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

function New-TrustedPayloadManifest {
  param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$ManifestPath
  )

  $payloadPrefix = [System.IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\') + '\'
  $entries = New-Object System.Collections.ArrayList
  $targetPaths = @{}

  function Add-TrustedPayloadFile {
    param(
      [Parameter(Mandatory = $true)][string]$SourcePath,
      [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ($RelativePath -match '[\r\n]' -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.StartsWith('..\')) {
      throw "Unsafe installer payload path: $RelativePath"
    }
    if ($RelativePath -imatch '^bin\\ssrvpn(?:\\|$)') {
      throw "Installer payload must not contain user-owned data: $RelativePath"
    }
    if ($RelativePath -imatch '^unins\d+\.(?:exe|dat|msg)$') {
      throw "Installer payload collides with Inno metadata: $RelativePath"
    }
    $pathKey = $RelativePath.ToLowerInvariant()
    if ($targetPaths.ContainsKey($pathKey)) {
      throw "Duplicate installer payload path: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
      throw "Installer payload file is missing: $SourcePath"
    }
    $targetPaths[$pathKey] = $true
    $hash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    [void]$entries.Add([pscustomobject]@{
        Path = $RelativePath
        Hash = $hash.ToLowerInvariant()
      })
  }

  foreach ($file in @(
      Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force |
        Sort-Object FullName
    )) {
    $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $fullPath.StartsWith(
        $payloadPrefix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Installer payload escaped its source root: $fullPath"
    }
    Add-TrustedPayloadFile -SourcePath $fullPath `
      -RelativePath $fullPath.Substring($payloadPrefix.Length)
  }

  foreach ($helperName in @(
      'stop_ssrvpn_processes.ps1',
      'proxy_transaction_state.ps1',
      'tun_ownership.ps1',
      'program_files_transaction.ps1'
    )) {
    Add-TrustedPayloadFile `
      -SourcePath (Join-Path $projectRoot "installer\$helperName") `
      -RelativePath "installer\$helperName"
  }

  $manifestParent = [System.IO.Path]::GetDirectoryName($ManifestPath)
  New-Item -ItemType Directory -Path $manifestParent -Force | Out-Null
  $manifestLines = @(
    $entries | Sort-Object Path | ForEach-Object {
      "$($_.Hash)  $($_.Path)"
    }
  )
  $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText(
    $ManifestPath,
    (($manifestLines -join "`n") + "`n"),
    $utf8NoBom
  )
}

$compilerCandidates = @($InnoCompiler, $env:INNO_SETUP_COMPILER)
if ($env:LOCALAPPDATA) {
  $compilerCandidates += Join-Path `
    $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
}
if (${env:ProgramFiles(x86)}) {
  $compilerCandidates += Join-Path `
    ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
}
if ($env:ProgramFiles) {
  $compilerCandidates += Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'
}
$compiler = $compilerCandidates |
  Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
  Select-Object -First 1
if (-not $compiler) {
  $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($command) {
    $compiler = $command.Source
  }
}
if (-not $compiler) {
  throw 'Inno Setup 6.5 or newer compiler (ISCC.exe) was not found.'
}

$minimumCompilerVersion = [version]'6.5.0'
$versionInfo = (Get-Item -LiteralPath $compiler).VersionInfo
$probePath = Join-Path (
  [System.IO.Path]::GetTempPath()
) "ssrvpn-inno-version-$([Guid]::NewGuid().ToString('N')).iss"
$probeSource = @(
  '[Setup]',
  'AppName=SSRVPN Compiler Probe',
  'AppVersion=0.0',
  'DefaultDirName={tmp}\SSRVPN-Compiler-Probe',
  'Uninstallable=no',
  'Output=no',
  'PrivilegesRequired=lowest'
) -join "`r`n"
[System.IO.File]::WriteAllText(
  $probePath,
  "$probeSource`r`n",
  [System.Text.Encoding]::ASCII
)
try {
  $compilerBanner = @(& $compiler $probePath 2>&1)
  $probeExitCode = $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
}
if ($probeExitCode -ne 0) {
  throw "Unable to run the Inno Setup compiler version probe (exit $probeExitCode)."
}
$compilerBannerText = ($compilerBanner | ForEach-Object { [string]$_ }) -join "`n"
$versionMatch = [regex]::Match(
  $compilerBannerText,
  'Compiler engine version:\s*(?:Inno Setup\s+)?(\d+(?:\.\d+){1,3})'
)
$compilerVersionText = if ($versionMatch.Success) {
  $versionMatch.Groups[1].Value
} else {
  $fileVersionText = @(
    $versionInfo.FileVersion,
    $versionInfo.ProductVersion
  ) | Where-Object {
    $_ -and $_ -match '\d+(?:\.\d+){1,3}' -and
      [version]$matches[0] -gt [version]'0.0.0.0'
  } | Select-Object -First 1
  if ($fileVersionText) {
    [regex]::Match([string]$fileVersionText, '\d+(?:\.\d+){1,3}').Value
  }
}
if (-not $compilerVersionText) {
  throw "Unable to determine Inno Setup compiler version: $compiler"
}
$compilerVersion = [version]$compilerVersionText
if ($compilerVersion -lt $minimumCompilerVersion) {
  throw (
    "Inno Setup 6.5 or newer is required; found $compilerVersion at $compiler"
  )
}

$installerScript = Join-Path $projectRoot 'installer\SSRVPN.iss'
$payloadManifestPath = Join-Path ([System.IO.Path]::GetTempPath()) `
  "ssrvpn-expected-payload-$([Guid]::NewGuid().ToString('N')).sha256"
try {
  New-TrustedPayloadManifest -PayloadRoot $SourceDir `
    -ManifestPath $payloadManifestPath
  & $compiler `
    "/DAppVersion=$Version" `
    "/DSourceDir=$SourceDir" `
    "/DOutputDir=$OutputDir" `
    "/DProjectDir=$projectRoot" `
    "/DPayloadManifestPath=$payloadManifestPath" `
    $installerScript
  if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $payloadManifestPath -Force `
    -ErrorAction SilentlyContinue
}

$installerPath = Join-Path $OutputDir 'SSRVPN_Setup.exe'
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
  throw "Installer was not created: $installerPath"
}
if ((Get-Item -LiteralPath $installerPath).Length -le 1MB) {
  throw "Installer is unexpectedly small: $installerPath"
}

$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLower()
$hashPath = "$installerPath.sha256"
[System.IO.File]::WriteAllText(
  $hashPath,
  "$hash  SSRVPN_Setup.exe`n",
  [System.Text.Encoding]::ASCII
)

Write-Host "Created $installerPath"
Write-Host "Created $hashPath"
