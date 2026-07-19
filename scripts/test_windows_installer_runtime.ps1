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
  [ValidateSet(
    'late-pending',
    'none',
    'sequence',
    'foreign-same-name',
    'owned-marker-pending',
    'legacy-signature-pending',
    'legacy-signature-numeric',
    'legacy-foreign-same-name',
    'legacy-single-address',
    'legacy-wrong-route',
    'unmarked-signature'
  )][string]$ProbeMode,
  [int]$TunTimeoutMilliseconds
)

$global:SsrvpnTestProbeMode = $ProbeMode
$global:SsrvpnTestAdapterCalls = 0
$global:SsrvpnTestAddressCalls = 0
$global:SsrvpnTestRouteCalls = 0
$global:SsrvpnOwnedTunGuid = '11111111-1111-4111-8111-111111111111'
$global:SsrvpnForeignTunGuid = '22222222-2222-4222-8222-222222222222'
$global:SsrvpnLegacySignatureModes = @(
  'legacy-signature-pending',
  'legacy-signature-numeric',
  'unmarked-signature'
)

function Get-NetAdapter {
  [CmdletBinding()]
  param([switch]$IncludeHidden)

  $global:SsrvpnTestAdapterCalls++
  if (($global:SsrvpnTestProbeMode -eq 'late-pending' -and
      $global:SsrvpnTestAdapterCalls -ge 2) -or
      ($global:SsrvpnTestProbeMode -eq 'sequence' -and
      $global:SsrvpnTestAdapterCalls -eq 1) -or
      $global:SsrvpnLegacySignatureModes -contains
      $global:SsrvpnTestProbeMode -or
      $global:SsrvpnTestProbeMode -eq 'legacy-single-address' -or
      $global:SsrvpnTestProbeMode -eq 'legacy-wrong-route') {
    [pscustomobject]@{
      Name = 'Meta Tunnel'
      ifIndex = 4242
      InterfaceGuid = $global:SsrvpnOwnedTunGuid
    }
  } elseif ($global:SsrvpnTestProbeMode -eq 'foreign-same-name' -or
      $global:SsrvpnTestProbeMode -eq 'legacy-foreign-same-name') {
    [pscustomobject]@{
      Name = 'Meta Tunnel'
      ifIndex = 4343
      InterfaceGuid = $global:SsrvpnForeignTunGuid
    }
  } elseif ($global:SsrvpnTestProbeMode -eq 'owned-marker-pending') {
    [pscustomobject]@{
      Name = 'Unrelated Display Name'
      ifIndex = 4242
      InterfaceGuid = $global:SsrvpnOwnedTunGuid
    }
  }
}

function Get-NetIPAddress {
  [CmdletBinding()]
  param()

  $global:SsrvpnTestAddressCalls++
  if ($global:SsrvpnTestProbeMode -eq 'late-pending' -or
      ($global:SsrvpnTestProbeMode -eq 'sequence' -and
      $global:SsrvpnTestAddressCalls -eq 1) -or
      $global:SsrvpnLegacySignatureModes -contains
      $global:SsrvpnTestProbeMode -or
      $global:SsrvpnTestProbeMode -eq 'legacy-wrong-route') {
    [pscustomobject]@{ InterfaceIndex = 4242; IPAddress = '198.18.0.1' }
    [pscustomobject]@{
      InterfaceIndex = 4242
      IPAddress = 'fdfe:dcba:9876::1'
    }
  } elseif ($global:SsrvpnTestProbeMode -eq 'foreign-same-name' -or
      $global:SsrvpnTestProbeMode -eq 'legacy-foreign-same-name') {
    [pscustomobject]@{ InterfaceIndex = 4343; IPAddress = '10.99.0.1' }
  } elseif ($global:SsrvpnTestProbeMode -eq 'legacy-single-address') {
    [pscustomobject]@{ InterfaceIndex = 4242; IPAddress = '198.18.0.1' }
  } elseif ($global:SsrvpnTestProbeMode -eq 'owned-marker-pending') {
    [pscustomobject]@{ InterfaceIndex = 4242; IPAddress = '198.18.0.1' }
  }
}

function Get-NetRoute {
  [CmdletBinding()]
  param()

  $global:SsrvpnTestRouteCalls++
  if ($global:SsrvpnTestProbeMode -eq 'late-pending' -or
      ($global:SsrvpnTestProbeMode -eq 'sequence' -and
      $global:SsrvpnTestRouteCalls -le 2) -or
      $global:SsrvpnLegacySignatureModes -contains
      $global:SsrvpnTestProbeMode -or
      $global:SsrvpnTestProbeMode -eq 'legacy-single-address') {
    [pscustomobject]@{
      InterfaceIndex = 4242
      DestinationPrefix = '0.0.0.0/1'
    }
  } elseif ($global:SsrvpnTestProbeMode -eq 'foreign-same-name' -or
      $global:SsrvpnTestProbeMode -eq 'legacy-foreign-same-name') {
    [pscustomobject]@{
      InterfaceIndex = 4343
      DestinationPrefix = '10.99.0.0/24'
    }
  } elseif ($global:SsrvpnTestProbeMode -eq 'owned-marker-pending') {
    [pscustomobject]@{
      InterfaceIndex = 4242
      DestinationPrefix = '198.18.0.0/16'
    }
  } elseif ($global:SsrvpnTestProbeMode -eq 'legacy-wrong-route') {
    [pscustomobject]@{
      InterfaceIndex = 4242
      DestinationPrefix = '198.18.0.0/16'
    }
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
  $tunMarkerPath = Join-Path (
    [System.IO.Path]::GetDirectoryName($pidFile)
  ) 'tun_teardown.pending'

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

  [System.IO.File]::WriteAllText(
    $tunMarkerPath,
    '{"version":2,"interfaces":[],"baselineInterfaces":[{"index":1,"guid":"44444444-4444-4444-8444-444444444444"}]}',
    [System.Text.UTF8Encoding]::new($false)
  )
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
  Remove-Item -LiteralPath $tunMarkerPath -Force -ErrorAction Stop

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
  if ($stop.ExitCode -ne 0) {
    throw "No-TUN cleanup returned $($stop.ExitCode)."
  }
  if ([System.IO.File]::ReadAllText($noTunStatusPath) -cne 'OK') {
    throw 'No-TUN cleanup did not report OK.'
  }
  if (-not $ownedA.HasExited -or -not $ownedB.HasExited) {
    throw 'No-TUN cleanup left an exact mihomo process running.'
  }
  if (-not $installedApp.HasExited -or -not $installedLauncher.HasExited) {
    throw 'No-TUN cleanup left an exact app process running.'
  }
  if (Test-Path -LiteralPath $pidFile) {
    throw 'No-TUN cleanup left the stale core PID file behind.'
  }

  $unmarkedTunStatusPath = Join-Path $testRoot 'unmarked-signature.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $unmarkedTunStatusPath,
    '-ProbeMode', 'unmarked-signature',
    '-TunTimeoutMilliseconds', 300
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 0 -or
      [System.IO.File]::ReadAllText($unmarkedTunStatusPath) -cne 'OK') {
    throw 'A TUN signature without a persistent marker claimed ownership.'
  }

  foreach ($legacyCase in @(
    @{
      Marker = 'pending'
      Mode = 'legacy-signature-pending'
      StatusName = 'legacy-signature-pending.status'
    },
    @{
      Marker = '7,4242'
      Mode = 'legacy-signature-numeric'
      StatusName = 'legacy-signature-numeric.status'
    }
  )) {
    [System.IO.File]::WriteAllText(
      $tunMarkerPath,
      [string]$legacyCase.Marker,
      [System.Text.UTF8Encoding]::new($false)
    )
    $legacyStatusPath = Join-Path $testRoot $legacyCase.StatusName
    $stop = Start-Process powershell.exe -ArgumentList @(
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', $tunHarnessPath,
      '-StopScript', $stopScript,
      '-InstalledAppPath', $appPath,
      '-InstalledLauncherPath', $launcherPath,
      '-InstalledCorePath', $corePath,
      '-InstalledCorePidPath', $pidFile,
      '-StatusPath', $legacyStatusPath,
      '-ProbeMode', $legacyCase.Mode,
      '-TunTimeoutMilliseconds', 300
    ) -Wait -PassThru -WindowStyle Hidden
    if ($stop.ExitCode -ne 3 -or
        [System.IO.File]::ReadAllText($legacyStatusPath) -cne
        'TUN_TEARDOWN_PENDING') {
      throw "Legacy marker $($legacyCase.Marker) did not retain the strict TUN residual."
    }
    $migratedMarker = Get-Content -LiteralPath $tunMarkerPath -Encoding UTF8 `
      -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([int]$migratedMarker.version -ne 2 -or
        @($migratedMarker.interfaces).Count -ne 1 -or
        [int]$migratedMarker.interfaces[0].index -ne 4242 -or
        [string]$migratedMarker.interfaces[0].guid -cne
        '11111111-1111-4111-8111-111111111111') {
      throw "Legacy marker $($legacyCase.Marker) was not migrated to the stable TUN GUID."
    }
    Remove-Item -LiteralPath $tunMarkerPath -Force -ErrorAction Stop
  }

  foreach ($ambiguousMode in @(
    'legacy-single-address',
    'legacy-wrong-route'
  )) {
    [System.IO.File]::WriteAllText(
      $tunMarkerPath,
      'pending',
      [System.Text.UTF8Encoding]::new($false)
    )
    $ambiguousStatusPath = Join-Path $testRoot "$ambiguousMode.status"
    $stop = Start-Process powershell.exe -ArgumentList @(
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', $tunHarnessPath,
      '-StopScript', $stopScript,
      '-InstalledAppPath', $appPath,
      '-InstalledLauncherPath', $launcherPath,
      '-InstalledCorePath', $corePath,
      '-InstalledCorePidPath', $pidFile,
      '-StatusPath', $ambiguousStatusPath,
      '-ProbeMode', $ambiguousMode,
      '-TunTimeoutMilliseconds', 300
    ) -Wait -PassThru -WindowStyle Hidden
    if ($stop.ExitCode -ne 3 -or
        [System.IO.File]::ReadAllText($ambiguousStatusPath) -cne
        'TUN_TEARDOWN_PENDING' -or
        [System.IO.File]::ReadAllText($tunMarkerPath) -cne 'pending') {
      throw "Ambiguous legacy evidence $ambiguousMode did not fail closed."
    }
    Remove-Item -LiteralPath $tunMarkerPath -Force -ErrorAction Stop
  }

  [System.IO.File]::WriteAllText(
    $tunMarkerPath,
    'pending',
    [System.Text.UTF8Encoding]::new($false)
  )
  $legacyForeignStatusPath = Join-Path $testRoot `
    'legacy-foreign-same-name.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $legacyForeignStatusPath,
    '-ProbeMode', 'legacy-foreign-same-name',
    '-TunTimeoutMilliseconds', 300
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 3 -or
      [System.IO.File]::ReadAllText($legacyForeignStatusPath) -cne
      'TUN_TEARDOWN_PENDING') {
    throw 'Ambiguous legacy TUN ownership did not fail closed.'
  }
  if ([System.IO.File]::ReadAllText($tunMarkerPath) -cne 'pending') {
    throw 'A foreign same-name TUN was promoted to SSRVPN ownership.'
  }
  Remove-Item -LiteralPath $tunMarkerPath -Force -ErrorAction Stop

  $foreignTunStatusPath = Join-Path $testRoot 'foreign-same-name-tun.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $foreignTunStatusPath,
    '-ProbeMode', 'foreign-same-name',
    '-TunTimeoutMilliseconds', 300
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 0 -or
      [System.IO.File]::ReadAllText($foreignTunStatusPath) -cne 'OK') {
    throw 'Foreign same-name TUN blocked installer cleanup.'
  }

  [System.IO.File]::WriteAllText(
    $tunMarkerPath,
    '{"version":2,"interfaces":[{"index":4242,"guid":"11111111-1111-4111-8111-111111111111"}],"baselineInterfaces":[]}',
    [System.Text.UTF8Encoding]::new($false)
  )
  $ownedTunStatusPath = Join-Path $testRoot 'owned-marker-pending.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $ownedTunStatusPath,
    '-ProbeMode', 'owned-marker-pending',
    '-TunTimeoutMilliseconds', 300
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 3 -or
      [System.IO.File]::ReadAllText($ownedTunStatusPath) -cne
      'TUN_TEARDOWN_PENDING') {
    throw 'Owned TUN residual did not block installer cleanup.'
  }
  Remove-Item -LiteralPath $tunMarkerPath -Force -ErrorAction Stop

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  Start-Sleep -Milliseconds 300
  [System.IO.File]::WriteAllText($pidFile, "$($ownedA.Id)`n")
  [System.IO.File]::WriteAllText(
    $tunMarkerPath,
    '{"version":2,"interfaces":[],"baselineInterfaces":[{"index":1,"guid":"44444444-4444-4444-8444-444444444444"}]}',
    [System.Text.UTF8Encoding]::new($false)
  )

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
