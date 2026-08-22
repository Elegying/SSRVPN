$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
$stopScript = Join-Path $root `
  'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$transactionStateScript = Join-Path $root `
  'SSRVPN_Windows\installer\proxy_transaction_state.ps1'
$tempRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$testRoot = Join-Path $tempRoot `
  "ssrvpn-installer-test-$([Guid]::NewGuid().ToString('N'))"
$heldTransactionLock = $null
$heldTransactionLockAcquired = $false
$lockedPidStream = $null
$originalLocalAppData = $env:LOCALAPPDATA
$foreignMutexHolder = $null
$foreignMutexReadyPath = $null
$gatedInstalledApp = $null
$gatedPortableApp = $null

$stopSource = [System.IO.File]::ReadAllText($stopScript)
$transactionStateSource = [System.IO.File]::ReadAllText(
  $transactionStateScript)
if ($stopSource.Contains('function Enter-ProxyTransactionLock') -or
    -not $transactionStateSource.Contains(
      'function Enter-ProxyTransactionLock')) {
  throw 'The proxy transaction lock is not owned by its packaged helper.'
}
if ($stopSource -notmatch
    'if \(!GetExitCodeProcess\(process, out exitCode\)\)' -or
    $stopSource -match
    'if \(GetExitCodeProcess\(process, out exitCode\) &&') {
  throw 'Verified process termination does not fail closed on exit-code query errors.'
}

function Write-CorePidRecord {
  param(
    [Parameter(Mandatory = $true)][string]$PidPath,
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$ExpectedCorePath
  )

  $Process.Refresh()
  if ($Process.HasExited) {
    throw 'Cannot write a core identity record for an exited process.'
  }
  $livePath = [IO.Path]::GetFullPath($Process.MainModule.FileName)
  $expectedPath = [IO.Path]::GetFullPath($ExpectedCorePath)
  if (-not $livePath.Equals(
      $expectedPath,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The core identity fixture resolved an unexpected executable path.'
  }
  $record = [ordered]@{
    version = 1
    pid = [int]$Process.Id
    creationTimeUtcFileTime = (
      $Process.StartTime.ToUniversalTime().ToFileTimeUtc()
    ).ToString([Globalization.CultureInfo]::InvariantCulture)
    canonicalExecutablePath = $livePath
  } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText(
    $PidPath,
    "$record`n",
    [Text.UTF8Encoding]::new($false)
  )
}

function Get-InternetSettingsSnapshot {
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $item = Get-ItemProperty -Path $path -ErrorAction Stop
  $snapshot = [ordered]@{}
  foreach ($name in @(
    'ProxyEnable',
    'ProxyServer',
    'ProxyOverride',
    'AutoConfigURL',
    'AutoDetect'
  )) {
    $property = $item.PSObject.Properties[$name]
    $snapshot[$name] = if ($null -eq $property) {
      @{ Present = $false; Value = '' }
    } else {
      @{ Present = $true; Value = [string]$property.Value }
    }
  }
  return ($snapshot | ConvertTo-Json -Compress)
}

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

  $missingInstallRoot = Join-Path $testRoot 'missing-install-root'
  $missingPidStatusPath = Join-Path $testRoot 'missing-pid.status'
  $missingPidProbe = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', (Join-Path $missingInstallRoot 'bin\ssrvpn_windows_app.exe'),
    '-InstalledLauncherPath', (Join-Path $missingInstallRoot 'ssrvpn_windows.exe'),
    '-InstalledCorePath', (Join-Path $missingInstallRoot 'bin\mihomo.exe'),
    '-InstalledCorePidPath', (Join-Path $missingInstallRoot 'mihomo.pid'),
    '-StatusPath', $missingPidStatusPath
  ) -Wait -PassThru -WindowStyle Hidden
  if ($missingPidProbe.ExitCode -ne 0) {
    throw "Missing PID parent cleanup returned $($missingPidProbe.ExitCode)."
  }
  if ([System.IO.File]::ReadAllText($missingPidStatusPath) -cne 'OK') {
    throw 'Missing PID parent cleanup did not report OK.'
  }
  if (Test-Path -LiteralPath $missingInstallRoot) {
    throw 'Missing PID parent cleanup unexpectedly created the install root.'
  }

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
  $thirdPartyProcessPaths = @(
    (Join-Path $unrelatedRoot 'clash.exe'),
    (Join-Path $unrelatedRoot 'sing-box.exe'),
    (Join-Path $unrelatedRoot 'openvpn.exe'),
    (Join-Path $unrelatedRoot 'wireguard.exe'),
    (Join-Path $unrelatedRoot 'tailscale-ipn.exe'),
    (Join-Path $unrelatedRoot 'zerotier-one_x64.exe')
  )
  foreach ($thirdPartyPath in $thirdPartyProcessPaths) {
    Copy-Item -LiteralPath $corePath -Destination $thirdPartyPath
  }
  $appPath = Join-Path $processBin 'ssrvpn_windows_app.exe'
  $launcherPath = Join-Path $processRoot 'ssrvpn_windows.exe'
  $unrelatedAppPath = Join-Path $unrelatedRoot 'ssrvpn_windows_app.exe'
  $unrelatedLauncherPath = Join-Path $unrelatedRoot 'ssrvpn_windows.exe'
  foreach ($copyPath in @(
    $appPath, $launcherPath, $unrelatedAppPath, $unrelatedLauncherPath
  )) {
    Copy-Item -LiteralPath $corePath -Destination $copyPath
  }

  # A portable/older SSRVPN copy can own the app-wide mutex while its process
  # lives outside the active installation. The installer may stop only exact
  # installed-path processes, then must abort before touching the shared proxy
  # journal or WinINet state.
  $foreignMutexHolderPath = Join-Path $testRoot 'ssrvpn_mutex_holder.exe'
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class SsrvpnMutexHolder {
  public static int Main(string[] args) {
    bool createdNew;
    using (var gate = new Mutex(
        true, "Local\\SSRVPN_Windows_SingleInstance", out createdNew)) {
      if (!createdNew || args.Length != 1) return 2;
      File.WriteAllText(args[0], "ready");
      try {
        while (File.Exists(args[0])) Thread.Sleep(100);
      } finally {
        gate.ReleaseMutex();
      }
      return 0;
    }
  }
}
'@ -Language CSharp -OutputAssembly $foreignMutexHolderPath `
    -OutputType ConsoleApplication
  $foreignMutexReadyPath = Join-Path $testRoot 'foreign-mutex.ready'
  $foreignFixtureLocalAppData = Join-Path $testRoot 'foreign-localappdata'
  $foreignRuntimePath = Join-Path $foreignFixtureLocalAppData 'SSRVPN\runtime'
  [System.IO.Directory]::CreateDirectory($foreignRuntimePath) | Out-Null
  $foreignJournalPath = Join-Path $foreignRuntimePath `
    'system_proxy_backup.json'
  $foreignJournalContent = '{"foreignInstance":"must-remain-byte-for-byte"}'
  [System.IO.File]::WriteAllText(
    $foreignJournalPath,
    $foreignJournalContent,
    [System.Text.UTF8Encoding]::new($false)
  )
  $env:LOCALAPPDATA = $foreignFixtureLocalAppData
  $proxyBeforeForeignGate = Get-InternetSettingsSnapshot
  $foreignMutexHolder = Start-Process -FilePath $foreignMutexHolderPath `
    -ArgumentList @("`"$foreignMutexReadyPath`"") -PassThru
  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if (Test-Path -LiteralPath $foreignMutexReadyPath -PathType Leaf) { break }
    $foreignMutexHolder.Refresh()
    if ($foreignMutexHolder.HasExited) {
      throw "Foreign SSRVPN mutex fixture exited with code $($foreignMutexHolder.ExitCode)."
    }
    Start-Sleep -Milliseconds 100
  }
  if (-not (Test-Path -LiteralPath $foreignMutexReadyPath -PathType Leaf)) {
    throw 'Foreign SSRVPN mutex fixture did not become ready.'
  }
  $gatedInstalledApp = Start-Process -FilePath $appPath -PassThru
  $gatedPortableApp = Start-Process -FilePath $unrelatedAppPath -PassThru
  Start-Sleep -Milliseconds 300
  $foreignInstanceStatusPath = Join-Path $testRoot `
    'foreign-instance-active.status'
  $foreignInstanceStop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-StatusPath', $foreignInstanceStatusPath
  ) -Wait -PassThru -WindowStyle Hidden
  $gatedInstalledApp.Refresh()
  $gatedPortableApp.Refresh()
  $foreignMutexHolder.Refresh()
  if ($foreignInstanceStop.ExitCode -ne 2 -or
      [System.IO.File]::ReadAllText($foreignInstanceStatusPath) -cne
      'APP_INSTANCE_ACTIVE') {
    throw 'A foreign SSRVPN instance did not stop installer proxy cleanup.'
  }
  if (-not $gatedInstalledApp.HasExited) {
    throw 'Foreign-instance gate returned before the exact installed app stopped.'
  }
  if ($gatedPortableApp.HasExited -or $foreignMutexHolder.HasExited) {
    throw 'Foreign-instance gate stopped a portable SSRVPN fixture.'
  }
  if ([System.IO.File]::ReadAllText($foreignJournalPath) -cne
      $foreignJournalContent) {
    throw 'Foreign-instance gate changed the shared proxy recovery journal.'
  }
  if ((Get-InternetSettingsSnapshot) -cne $proxyBeforeForeignGate) {
    throw 'Foreign-instance gate changed Windows Internet Settings.'
  }
  Remove-Item -LiteralPath $foreignMutexReadyPath -Force
  if (-not $foreignMutexHolder.WaitForExit(5000) -or
      $foreignMutexHolder.ExitCode -ne 0) {
    throw 'Foreign SSRVPN mutex fixture did not release cleanly.'
  }
  Stop-Process -Id $gatedPortableApp.Id -Force
  $gatedPortableApp.WaitForExit()
  $foreignMutexHolder.Dispose()
  $foreignMutexHolder = $null
  $gatedInstalledApp.Dispose()
  $gatedInstalledApp = $null
  $gatedPortableApp.Dispose()
  $gatedPortableApp = $null
  $env:LOCALAPPDATA = $originalLocalAppData

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
    'unknown-empty-marker',
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
  $thirdPartyProcesses = @(
    foreach ($thirdPartyPath in $thirdPartyProcessPaths) {
      Start-Process -FilePath $thirdPartyPath -PassThru
    }
  )
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  $unrelatedApp = Start-Process -FilePath $unrelatedAppPath -PassThru
  $unrelatedLauncher = Start-Process -FilePath $unrelatedLauncherPath -PassThru
  Start-Sleep -Milliseconds 300
  $pidFile = Join-Path $processBin 'ssrvpn\mihomo.pid'
  New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName(
    $pidFile)) -Force | Out-Null
  Write-CorePidRecord `
    -PidPath $pidFile `
    -Process $ownedA `
    -ExpectedCorePath $corePath
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
  foreach ($thirdPartyProcess in $thirdPartyProcesses) {
    $thirdPartyProcess.Refresh()
  }
  $installedApp.Refresh()
  $installedLauncher.Refresh()
  $unrelatedApp.Refresh()
  $unrelatedLauncher.Refresh()
  if ($stop.ExitCode -ne 0) {
    throw "Owned installer cleanup returned $($stop.ExitCode), expected 0."
  }
  $foreignStatus = [System.IO.File]::ReadAllText($foreignStatusPath)
  if ($foreignStatus -cne 'OK') {
    throw "Owned installer cleanup reported $foreignStatus."
  }
  if (-not $ownedA.HasExited -or -not $ownedB.HasExited -or
      -not $installedApp.HasExited -or -not $installedLauncher.HasExited) {
    throw 'Owned installer cleanup did not stop an installed process.'
  }
  $stoppedThirdPartyProcesses = @(
    $thirdPartyProcesses | Where-Object { $_.HasExited }
  )
  if ($unrelated.HasExited -or $stoppedThirdPartyProcesses.Count -gt 0 -or
      $unrelatedApp.HasExited -or
      $unrelatedLauncher.HasExited) {
    throw 'Owned installer cleanup stopped an unrelated process.'
  }
  if (Test-Path -LiteralPath $pidFile) {
    throw 'Owned installer cleanup retained the stale core PID record.'
  }

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  Start-Sleep -Milliseconds 300
  Write-CorePidRecord `
    -PidPath $pidFile `
    -Process $ownedA `
    -ExpectedCorePath $corePath

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

  $emptyMarkerCore = Start-Process -FilePath $corePath -PassThru
  $emptyMarkerApp = Start-Process -FilePath $appPath -PassThru
  Start-Sleep -Milliseconds 300
  Write-CorePidRecord `
    -PidPath $pidFile `
    -Process $emptyMarkerCore `
    -ExpectedCorePath $corePath
  [System.IO.File]::WriteAllText(
    $tunMarkerPath,
    '{"version":2,"interfaces":[],"baselineInterfaces":[]}',
    [System.Text.UTF8Encoding]::new($false)
  )
  $emptyMarkerStatusPath = Join-Path $testRoot 'empty-marker.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $emptyMarkerStatusPath,
    '-ProbeMode', 'unknown-empty-marker',
    '-TunTimeoutMilliseconds', 300
  ) -Wait -PassThru -WindowStyle Hidden
  $emptyMarkerCore.Refresh()
  $emptyMarkerApp.Refresh()
  if ($stop.ExitCode -ne 3 -or
      [System.IO.File]::ReadAllText($emptyMarkerStatusPath) -cne
      'TUN_TEARDOWN_PENDING') {
    throw 'An empty structured TUN marker did not fail closed.'
  }
  if ($emptyMarkerCore.HasExited -or $emptyMarkerApp.HasExited) {
    throw 'Empty TUN ownership stopped processes before capture succeeded.'
  }
  if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf) -or
      -not (Test-Path -LiteralPath $tunMarkerPath -PathType Leaf)) {
    throw 'Empty TUN ownership removed durable recovery evidence.'
  }
  Stop-Process -Id $emptyMarkerCore.Id, $emptyMarkerApp.Id -Force
  $emptyMarkerCore.WaitForExit()
  $emptyMarkerApp.WaitForExit()
  Remove-Item -LiteralPath $tunMarkerPath -Force -ErrorAction Stop

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $installedApp = Start-Process -FilePath $appPath -PassThru
  $installedLauncher = Start-Process -FilePath $launcherPath -PassThru
  Start-Sleep -Milliseconds 300
  Write-CorePidRecord `
    -PidPath $pidFile `
    -Process $ownedA `
    -ExpectedCorePath $corePath

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

  [System.IO.Directory]::CreateDirectory($pidFile) | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $pidFile 'unexpected-entry'),
    'must not be recursively removed',
    [System.Text.UTF8Encoding]::new($false)
  )
  $pidDirectoryStatusPath = Join-Path $testRoot 'pid-path-directory.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $pidDirectoryStatusPath,
    '-ProbeMode', 'none',
    '-TunTimeoutMilliseconds', 1000
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 3 -or
      [System.IO.File]::ReadAllText($pidDirectoryStatusPath) -cne
      'PID_CLEANUP_FAILED' -or
      -not (Test-Path -LiteralPath $pidFile -PathType Container)) {
    throw 'A PID path directory was accepted as successful cleanup.'
  }
  Remove-Item -LiteralPath $pidFile -Recurse -Force -ErrorAction Stop

  [System.IO.File]::WriteAllText(
    $pidFile,
    '{"version":1,"pid":999999,"creationTimeUtcFileTime":"1","canonicalExecutablePath":"stale"}',
    [System.Text.UTF8Encoding]::new($false)
  )
  $lockedPidStream = New-Object System.IO.FileStream -ArgumentList @(
    $pidFile,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::Read
  )
  $lockedPidStatusPath = Join-Path $testRoot 'locked-pid.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $lockedPidStatusPath,
    '-ProbeMode', 'none',
    '-TunTimeoutMilliseconds', 1000
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 3 -or
      [System.IO.File]::ReadAllText($lockedPidStatusPath) -cne
      'PID_CLEANUP_FAILED' -or
      -not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    throw 'A locked PID file was accepted as successful cleanup.'
  }
  $lockedPidStream.Dispose()
  $lockedPidStream = $null

  $stalePidStatusPath = Join-Path $testRoot 'stale-pid.status'
  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $tunHarnessPath,
    '-StopScript', $stopScript,
    '-InstalledAppPath', $appPath,
    '-InstalledLauncherPath', $launcherPath,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile,
    '-StatusPath', $stalePidStatusPath,
    '-ProbeMode', 'none',
    '-TunTimeoutMilliseconds', 1000
  ) -Wait -PassThru -WindowStyle Hidden
  if ($stop.ExitCode -ne 0 -or
      [System.IO.File]::ReadAllText($stalePidStatusPath) -cne 'OK' -or
      (Test-Path -LiteralPath $pidFile)) {
    throw 'Unlocked stale PID cleanup did not report OK.'
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
  Write-CorePidRecord `
    -PidPath $pidFile `
    -Process $ownedA `
    -ExpectedCorePath $corePath
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
  $env:LOCALAPPDATA = $originalLocalAppData
  foreach ($fixtureProcess in @(
    $gatedInstalledApp,
    $gatedPortableApp,
    $foreignMutexHolder
  )) {
    if ($null -ne $fixtureProcess) {
      $fixtureProcess.Refresh()
      if (-not $fixtureProcess.HasExited) {
        $fixtureProcess.Kill()
      }
      $fixtureProcess.Dispose()
    }
  }
  if ($null -ne $lockedPidStream) {
    $lockedPidStream.Dispose()
  }
  if ($null -ne $heldTransactionLock) {
    if ($heldTransactionLockAcquired) {
      try {
        $heldTransactionLock.Unlock(0, 1)
      } catch {
      }
    }
    $heldTransactionLock.Dispose()
  }
  Get-Process mihomo, clash, sing-box, openvpn, wireguard, tailscale-ipn, `
    zerotier-one_x64, ssrvpn_windows, ssrvpn_windows_app `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($testRoot) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
