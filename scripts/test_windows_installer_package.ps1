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
$upgradeLog = Join-Path $logDir 'upgrade.log'
$uninstallLog = Join-Path $logDir 'uninstall.log'
$uninstaller = Join-Path $installDir 'unins000.exe'
$uninstallFailure = $null
$installedAppProcessId = $null
$preservedSentinels = @(
  (Join-Path $installDir 'bin\ssrvpn\upgrade-preserve.sentinel'),
  (Join-Path $env:LOCALAPPDATA 'SSRVPN\ssrvpn\upgrade-preserve.sentinel'),
  (Join-Path $env:LOCALAPPDATA 'SSRVPN\window_state.json')
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

try {
  $installExitCode = Invoke-SmokeProcess `
    -FilePath $installer `
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

  foreach ($sentinel in $preservedSentinels) {
    New-Item -ItemType Directory -Path (Split-Path -Path $sentinel -Parent) `
      -Force | Out-Null
    [System.IO.File]::WriteAllText($sentinel, 'ssrvpn-upgrade-preserve')
  }
  New-CacheSentinels

  $upgradeExitCode = Invoke-SmokeProcess `
    -FilePath $installer `
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

  Start-Process -FilePath (Join-Path $installDir 'ssrvpn_windows.exe') `
    -WorkingDirectory $installDir | Out-Null

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
      }
    } catch {
      $uninstallFailure = $_.Exception.Message
    }
  }
  foreach ($sentinel in $preservedSentinels) {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
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
foreach ($cacheRoot in $cacheRoots) {
  if (Test-Path -LiteralPath $cacheRoot) {
    throw "Uninstaller left WebView cache behind: $cacheRoot"
  }
}

Write-Host "Windows installer install/uninstall smoke test passed. Logs: $logDir"
