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
$upgradeInstaller = Join-Path $logDir 'SSRVPN_Setup_upgrade.exe'
Copy-Item -LiteralPath $sourceInstaller -Destination $installInstaller -Force
Copy-Item -LiteralPath $sourceInstaller -Destination $upgradeInstaller -Force
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
  Wait-PathAbsent -Path $installInstaller
  Assert-SingleMachineShortcut

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
  Assert-SingleMachineShortcut
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
    $upgradeInstaller,
    $userDesktopShortcutPath,
    $desktopShortcutPath,
    $userStartMenuShortcutPath,
    $startMenuShortcutPath
  )) {
    Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
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
if (Test-Path -LiteralPath $uninstallRegistryPath) {
  throw "Uninstaller left its registry entry behind: $uninstallRegistryPath"
}

Write-Host "Windows installer install/uninstall smoke test passed. Logs: $logDir"
