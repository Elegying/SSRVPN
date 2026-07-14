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

$compilerCandidates = @($InnoCompiler, $env:INNO_SETUP_COMPILER)
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
$compilerBanner = @(& $compiler '/?' 2>&1)
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
& $compiler `
  "/DAppVersion=$Version" `
  "/DSourceDir=$SourceDir" `
  "/DOutputDir=$OutputDir" `
  "/DProjectDir=$projectRoot" `
  $installerScript
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup failed with exit code $LASTEXITCODE"
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
