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

  $tunHarnessPath = Join-Path $testRoot 'tun-stop-harness.ps1'
  [System.IO.File]::WriteAllText(
    $tunHarnessPath,
    @'
param(
  [Parameter(Mandatory = $true)][string]$StopScript,
  [Parameter(Mandatory = $true)][string]$InstalledAppPath,
  [Parameter(Mandatory = $true)][string]$InstalledLauncherPath,
  [Parameter(Mandatory = $true)][string]$InstalledCorePath,
  [Parameter(Mandatory = $true)][string]$InstalledCorePidPath,
  [Parameter(Mandatory = $true)][string]$StatusPath,
  [ValidateSet('late-pending', 'none', 'sequence')][string]$ProbeMode,
  [int]$TunTimeoutMilliseconds
)

$script:ProbeMode = $ProbeMode
$script:AdapterCalls = 0
$script:AddressCalls = 0
$script:RouteCalls = 0

function Get-NetAdapter {
  [CmdletBinding()]
  param([switch]$IncludeHidden)

  $script:AdapterCalls++
  if (($script:ProbeMode -eq 'late-pending' -and
      $script:AdapterCalls -ge 2) -or
      ($script:ProbeMode -eq 'sequence' -and
      $script:AdapterCalls -eq 1)) {
    [pscustomobject]@{ Name = 'Meta Tunnel'; ifIndex = 4242 }
  }
}

function Get-NetIPAddress {
  [CmdletBinding()]
  param()

  $script:AddressCalls++
  if ($script:ProbeMode -eq 'late-pending' -or
      ($script:ProbeMode -eq 'sequence' -and
      $script:AddressCalls -eq 1)) {
    [pscustomobject]@{ InterfaceIndex = 4242 }
  }
}

function Get-NetRoute {
  [CmdletBinding()]
  param()

  $script:RouteCalls++
  if ($script:ProbeMode -eq 'late-pending' -or
      ($script:ProbeMode -eq 'sequence' -and
      $script:RouteCalls -le 2)) {
    [pscustomobject]@{ InterfaceIndex = 4242 }
  }
}

& $StopScript `
  -InstalledAppPath $InstalledAppPath `
  -InstalledLauncherPath $InstalledLauncherPath `
  -InstalledCorePath $InstalledCorePath `
  -InstalledCorePidPath $InstalledCorePidPath `
  -StatusPath $StatusPath `
  -TunTeardownTimeoutMilliseconds $TunTimeoutMilliseconds
exit $LASTEXITCODE
'@,
    [System.Text.Encoding]::ASCII
  )

  $bestEffortProbe = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', 'relative.exe',
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-StatusPath', $testRoot
  ) -Wait -PassThru -WindowStyle Hidden
  if ($bestEffortProbe.ExitCode -ne 3) {
    throw 'A status write failure changed the cleanup exit code.'
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
  $lockStatusPath = Join-Path $testRoot 'lock.status'
  $lockProbe = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-StatusPath', $lockStatusPath,
    '-ProxyTransactionLockTimeoutMilliseconds', 500
  ) -Wait -PassThru -WindowStyle Hidden
  if ($lockProbe.ExitCode -ne 3) {
    throw "Contended proxy transaction lock returned $($lockProbe.ExitCode), expected 3."
  }
  if ([System.IO.File]::ReadAllText($lockStatusPath) -cne 'LOCK_BUSY') {
    throw 'Contended proxy transaction lock did not report LOCK_BUSY.'
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

  $foreignStatusPath = Join-Path $testRoot 'foreign.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $foreignStatusPath
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
  $foreignStatus = [System.IO.File]::ReadAllText($foreignStatusPath)
  if ($foreignStatus -cne 'FOREIGN_INSTANCE') {
    throw "Foreign-instance ownership gate reported $foreignStatus."
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

  $lateStatusPath = Join-Path $testRoot 'tun-late-pending.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $lateStatusPath,
    '-ProbeMode', 'late-pending',
    '-TunTimeoutMilliseconds', 300
  ) -Wait -PassThru -WindowStyle Hidden
  $ownedA.Refresh()
  $ownedB.Refresh()
  $installedApp.Refresh()
  $installedLauncher.Refresh()
  if ($stop.ExitCode -ne 3) {
    throw "Late TUN teardown returned $($stop.ExitCode), expected 3."
  }
  if ([System.IO.File]::ReadAllText($lateStatusPath) -cne
      'TUN_TEARDOWN_PENDING') {
    throw 'Late TUN teardown did not report TUN_TEARDOWN_PENDING.'
  }
  if (-not $ownedA.HasExited -or -not $ownedB.HasExited -or
      -not $installedApp.HasExited -or -not $installedLauncher.HasExited) {
    throw 'Late TUN teardown returned before exact processes stopped.'
  }
  if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    throw 'Late TUN teardown removed the core PID before cleanup completed.'
  }

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  Start-Sleep -Milliseconds 300
  [System.IO.File]::WriteAllText($pidFile, "$($ownedA.Id)`n")

  $noTunStatusPath = Join-Path $testRoot 'no-tun.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $noTunStatusPath,
    '-ProbeMode', 'none',
    '-TunTimeoutMilliseconds', 1000
  ) -Wait -PassThru -WindowStyle Hidden
  $ownedA.Refresh()
  $ownedB.Refresh()
  $installedApp.Refresh()
  $installedLauncher.Refresh()
  if (-not $ownedA.HasExited -or -not $ownedB.HasExited) {
    throw 'No-TUN cleanup left an exact mihomo process running.'
  }
  if (-not $installedApp.HasExited -or -not $installedLauncher.HasExited) {
    throw 'No-TUN cleanup left an exact app process running.'
  }
  if ($stop.ExitCode -ne 0) {
    throw "No-TUN cleanup returned $($stop.ExitCode)."
  }
  if ([System.IO.File]::ReadAllText($noTunStatusPath) -cne 'OK') {
    throw 'No-TUN cleanup did not report OK.'
  }
  if (Test-Path -LiteralPath $pidFile) {
    throw 'No-TUN cleanup left the stale core PID file behind.'
  }

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  Start-Sleep -Milliseconds 300
  [System.IO.File]::WriteAllText($pidFile, "$($ownedA.Id)`n")

  $successStatusPath = Join-Path $testRoot 'success.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $successStatusPath,
    '-ProbeMode', 'sequence',
    '-TunTimeoutMilliseconds', 1000
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
  if ([System.IO.File]::ReadAllText($successStatusPath) -cne 'OK') {
    throw 'Verified installer cleanup did not report OK.'
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
