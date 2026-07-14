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

$installer = [System.IO.Path]::GetFullPath($InstallerPath)
if ([System.IO.Path]::GetFileName($installer) -ne 'SSRVPN_Setup.exe' -or
    -not (Test-Path -LiteralPath $installer -PathType Leaf)) {
  throw "SSRVPN_Setup.exe was not found: $installer"
}

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\SSRVPN'
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
$installLog = Join-Path $logDir 'install.log'
$uninstallLog = Join-Path $logDir 'uninstall.log'
$uninstaller = Join-Path $installDir 'unins000.exe'
$uninstallFailure = $null
$installedAppProcessId = $null

try {
  $install = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SP-',
    "/LOG=$installLog"
  )
  if ($install.ExitCode -ne 0) {
    throw "SSRVPN installer exited with code $($install.ExitCode). Log: $installLog"
  }

  foreach ($relativePath in @(
    'ssrvpn_windows.exe',
    'bin\ssrvpn_windows_app.exe',
    'unins000.exe'
  )) {
    $installedPath = Join-Path $installDir $relativePath
    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
      throw "Installed package is missing $relativePath`: $installDir"
    }
  }

  $installedAppPath = [System.IO.Path]::GetFullPath(
    (Join-Path $installDir 'bin\ssrvpn_windows_app.exe')
  )
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
    if ($runningInstalledApp) { break }
    Start-Sleep -Milliseconds 250
  }
  if (-not $runningInstalledApp) {
    throw 'The uninstaller must stop the running installed app; no installed app was running.'
  }
  $installedAppProcessId = [int]$runningInstalledApp.Id
} finally {
  if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
    $uninstall = Start-Process -FilePath $uninstaller -Wait -PassThru `
      -ArgumentList @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        "/LOG=$uninstallLog"
      )
    if ($uninstall.ExitCode -ne 0) {
      $uninstallFailure =
        "SSRVPN uninstaller exited with code $($uninstall.ExitCode). " +
        "Log: $uninstallLog"
    }
  }
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

Write-Host "Windows installer install/uninstall smoke test passed. Logs: $logDir"
