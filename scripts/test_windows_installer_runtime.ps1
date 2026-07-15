$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
$stopScript = Join-Path $root `
  'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$tempRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$testRoot = Join-Path $tempRoot `
  "ssrvpn-installer-test-$([Guid]::NewGuid().ToString('N'))"
$heldTransactionLock = $null
$heldTransactionLockAcquired = $false

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

  $processRoot = Join-Path $testRoot 'process\installed'
  $processBin = Join-Path $processRoot 'bin'
  $unrelatedRoot = Join-Path $testRoot 'process\other-product'
  New-Item -ItemType Directory -Path $processBin -Force | Out-Null
  New-Item -ItemType Directory -Path $unrelatedRoot -Force | Out-Null
  $corePath = Join-Path $processBin 'mihomo.exe'
  Add-Type -TypeDefinition @'
using System.Threading;
public static class Program {
  public static void Main() { Thread.Sleep(600000); }
}
'@ -Language CSharp -OutputAssembly $corePath -OutputType ConsoleApplication
  $unrelatedCorePath = Join-Path $unrelatedRoot 'mihomo.exe'
  Copy-Item -LiteralPath $corePath -Destination $unrelatedCorePath
  $appPath = Join-Path $processBin 'ssrvpn_windows_app.exe'
  $launcherPath = Join-Path $processRoot 'ssrvpn_windows.exe'
  $unrelatedAppPath = Join-Path $unrelatedRoot 'ssrvpn_windows_app.exe'
  $unrelatedLauncherPath = Join-Path $unrelatedRoot 'ssrvpn_windows.exe'
  foreach ($copyPath in @(
    $appPath, $launcherPath, $unrelatedAppPath, $unrelatedLauncherPath
  )) {
    Copy-Item -LiteralPath $corePath -Destination $copyPath
  }

  $runtimePath = Join-Path $env:LOCALAPPDATA 'SSRVPN\runtime'
  [System.IO.Directory]::CreateDirectory($runtimePath) | Out-Null
  $transactionLockPath = Join-Path $runtimePath `
    'system_proxy_transaction.lock'
  $transactionFileShare = [System.IO.FileShare](
    [int][System.IO.FileShare]::ReadWrite -bor
    [int][System.IO.FileShare]::Delete)
  $heldTransactionLock = New-Object System.IO.FileStream -ArgumentList @(
    $transactionLockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    $transactionFileShare
  )
  $heldTransactionLock.Lock(0, 1)
  $heldTransactionLockAcquired = $true
  $lockProbe = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-ProxyTransactionLockTimeoutMilliseconds', 500
  ) -Wait -PassThru -WindowStyle Hidden
  if ($lockProbe.ExitCode -ne 3) {
    throw "Contended proxy transaction lock returned $($lockProbe.ExitCode), expected 3."
  }
  $heldTransactionLock.Unlock(0, 1)
  $heldTransactionLockAcquired = $false
  $heldTransactionLock.Dispose()
  $heldTransactionLock = $null

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $unrelated = Start-Process -FilePath $unrelatedCorePath -PassThru
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  $unrelatedApp = Start-Process -FilePath $unrelatedAppPath -PassThru
  $unrelatedLauncher = Start-Process -FilePath $unrelatedLauncherPath -PassThru
  Start-Sleep -Milliseconds 300
  $pidFile = Join-Path $processBin 'ssrvpn\mihomo.pid'
  New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName(
    $pidFile)) -Force | Out-Null
  [System.IO.File]::WriteAllText($pidFile, "$($ownedA.Id)`n")

  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile
  ) -Wait -PassThru -WindowStyle Hidden
  $ownedA.Refresh()
  $ownedB.Refresh()
  $unrelated.Refresh()
  $installedApp.Refresh()
  $installedLauncher.Refresh()
  $unrelatedApp.Refresh()
  $unrelatedLauncher.Refresh()
  if ($stop.ExitCode -ne 3) {
    throw "Foreign-instance ownership gate returned $($stop.ExitCode), expected 3."
  }
  if ($ownedA.HasExited -or $ownedB.HasExited -or
      $installedApp.HasExited -or $installedLauncher.HasExited) {
    throw 'Foreign-instance ownership gate stopped an installed process.'
  }
  if ($unrelated.HasExited -or $unrelatedApp.HasExited -or
      $unrelatedLauncher.HasExited) {
    throw 'Foreign-instance ownership gate stopped a portable process.'
  }
  if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    throw 'Foreign-instance ownership gate modified installed runtime files.'
  }

  Stop-Process -Id $unrelated.Id, $unrelatedApp.Id, $unrelatedLauncher.Id `
    -Force -ErrorAction Stop
  $unrelated.WaitForExit()
  $unrelatedApp.WaitForExit()
  $unrelatedLauncher.WaitForExit()

  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile
  ) -Wait -PassThru -WindowStyle Hidden
  $ownedA.Refresh()
  $ownedB.Refresh()
  $installedApp.Refresh()
  $installedLauncher.Refresh()
  if (-not $ownedA.HasExited -or -not $ownedB.HasExited) {
    throw 'A mihomo process from the exact active installation path survived.'
  }
  if (-not $installedApp.HasExited -or -not $installedLauncher.HasExited) {
    throw 'An executable from the exact active installation path survived.'
  }
  if ($stop.ExitCode -ne 0) {
    throw "Verified installer cleanup returned $($stop.ExitCode)."
  }

  Write-Host 'Windows installer runtime tests passed.'
} finally {
  if ($null -ne $heldTransactionLock) {
    if ($heldTransactionLockAcquired) {
      try {
        $heldTransactionLock.Unlock(0, 1)
      } catch {
      }
    }
    $heldTransactionLock.Dispose()
  }
  Get-Process mihomo, ssrvpn_windows, ssrvpn_windows_app `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($testRoot) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
