param(
  [string]$InstalledAppPath = '',
  [string]$InstalledLauncherPath = '',
  [string]$InstalledCorePath = '',
  [string]$InstalledCorePidPath = '',
  [string]$StatusPath = '',
  [switch]$RequireRecoveryCleanup,
  [ValidateRange(100, 8000)]
  [int]$TunTeardownTimeoutMilliseconds = 8000,
  [ValidateRange(100, 30000)]
  [int]$ProxyTransactionLockTimeoutMilliseconds = 10000
)

$ErrorActionPreference = 'Stop'

$proxyTransactionStatePath = Join-Path $PSScriptRoot 'proxy_transaction_state.ps1'
if (-not (Test-Path -LiteralPath $proxyTransactionStatePath -PathType Leaf)) {
  throw 'Proxy transaction state helper is missing.'
}
. $proxyTransactionStatePath

$script:StopStatusValues = @(
  'OK',
  'LOCK_BUSY',
  'LOCK_FAILED',
  'INSTANCE_GATE_FAILED',
  'IDENTITY_UNVERIFIED',
  'FOREIGN_INSTANCE',
  'APP_STILL_RUNNING',
  'PROXY_UNSAFE',
  'PROCESSES_STILL_RUNNING',
  'TUN_TEARDOWN_PENDING',
  'RECOVERY_CLEANUP_PENDING',
  'INTERNAL_ERROR'
)

function Set-StopStatus {
  param([Parameter(Mandatory = $true)][string]$Status)

  if ([string]::IsNullOrWhiteSpace($StatusPath) -or
      $script:StopStatusValues -cnotcontains $Status) {
    return
  }
  try {
    [System.IO.File]::WriteAllText(
      $StatusPath, $Status, [System.Text.Encoding]::ASCII)
  } catch {
    # Status is diagnostic only; cleanup exit codes remain authoritative.
  }
}

Set-StopStatus -Status 'INTERNAL_ERROR'

function Enter-ProxyTransactionLock {
  param([Parameter(Mandatory = $true)][int]$TimeoutMilliseconds)

  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
      -not [System.IO.Path]::IsPathRooted($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is unavailable for the proxy transaction lock.'
  }
  $runtimePath = Join-Path $env:LOCALAPPDATA 'SSRVPN\runtime'
  [System.IO.Directory]::CreateDirectory($runtimePath) | Out-Null
  $lockPath = Join-Path $runtimePath 'system_proxy_transaction.lock'
  $fileShare = [System.IO.FileShare](
    [int][System.IO.FileShare]::ReadWrite -bor
    [int][System.IO.FileShare]::Delete)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

  while ($true) {
    $stream = $null
    try {
      $stream = New-Object System.IO.FileStream -ArgumentList @(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        $fileShare
      )
      $stream.Lock(0, 1)
      return $stream
    } catch [System.IO.IOException] {
      if ($null -ne $stream) { $stream.Dispose() }
      if ([DateTime]::UtcNow -ge $deadline) {
        throw [System.TimeoutException]::new(
          'Timed out waiting for the proxy transaction lock.')
      }
      Start-Sleep -Milliseconds 100
    } catch {
      if ($null -ne $stream) { $stream.Dispose() }
      throw
    }
  }
}

$script:ProxyTransactionLockStream = $null
try {
  # Keep the only strong reference at script scope. Process exit releases the
  # byte-range lock even if installer cleanup terminates unexpectedly.
  $script:ProxyTransactionLockStream = Enter-ProxyTransactionLock `
    -TimeoutMilliseconds $ProxyTransactionLockTimeoutMilliseconds
} catch [System.TimeoutException] {
  Set-StopStatus -Status 'LOCK_BUSY'
  Write-Warning "Could not acquire the proxy transaction lock: $($_.Exception.Message)"
  exit 3
} catch {
  Set-StopStatus -Status 'LOCK_FAILED'
  Write-Warning "Could not acquire the proxy transaction lock: $($_.Exception.Message)"
  exit 3
}

$script:AppInstanceMutex = $null
try {
  # Keeping this named object alive closes the stop-before-restore launch gap.
  # Existing apps keep running, while any new installed or portable child sees
  # ERROR_ALREADY_EXISTS and exits before it can replace the global journal.
  $script:AppInstanceMutex = New-Object System.Threading.Mutex -ArgumentList @(
    $false,
    'Local\SSRVPN_Windows_SingleInstance'
  )
} catch {
  Set-StopStatus -Status 'INSTANCE_GATE_FAILED'
  Write-Warning "Could not reserve the SSRVPN app instance gate: $($_.Exception.Message)"
  exit 3
}

$currentSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
$script:OwnedProxyOverride = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;' +
  '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;' +
  '172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;' +
  '192.168.*'

function Get-ProcessesByName {
  param([Parameter(Mandatory = $true)][string]$Name)

  try {
    $candidates = @(
      Get-CimInstance -ClassName Win32_Process -Filter "Name = '$Name'" `
        -ErrorAction Stop
    )
  } catch {
    $cimError = $_.Exception.Message
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    try {
      $candidates = @(
        Get-Process -ErrorAction Stop |
          Where-Object {
            $_.ProcessName -ieq $processName
          } |
          Where-Object {
            $_.SessionId -eq $currentSessionId
          } |
          ForEach-Object {
            $executablePath = $_.Path
            if (-not $executablePath) {
              throw "Executable path is unavailable for PID $($_.Id)."
            }
            [pscustomobject]@{
              ProcessId = [int]$_.Id
              ExecutablePath = $executablePath
              SessionId = [int]$_.SessionId
            }
          }
      )
    } catch {
      throw "CIM enumeration failed ($cimError); Get-Process fallback failed: $($_.Exception.Message)"
    }
  }

  $expectedProcessName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
  return @(
    foreach ($candidate in $candidates) {
      $processId = 0
      if ($null -eq $candidate.PSObject.Properties['ProcessId'] -or
          -not [int]::TryParse(
            [string]$candidate.ProcessId, [ref]$processId) -or
          $processId -le 0) {
        throw "Invalid process identity returned while enumerating $Name."
      }
      $candidateSessionId = 0
      if ($null -eq $candidate.PSObject.Properties['SessionId'] -or
          -not [int]::TryParse(
            [string]$candidate.SessionId, [ref]$candidateSessionId)) {
        throw "Incomplete process identity returned for PID $processId."
      }
      if ($candidateSessionId -ne $currentSessionId) { continue }
      if (-not $candidate.ExecutablePath) {
        throw "Incomplete process identity returned for PID $processId."
      }

      # Re-open the PID and compare its live name, session and image path. This
      # prevents a stale CIM row or PID reuse from being trusted as ownership.
      $live = Get-Process -Id $processId -ErrorAction Stop
      $livePath = $live.Path
      if (-not $livePath -or
          $live.ProcessName -ine $expectedProcessName -or
          $live.SessionId -ne $currentSessionId -or
          -not (Test-ExactPath -Actual $livePath `
            -Expected ([string]$candidate.ExecutablePath))) {
        throw "Process identity changed while verifying PID $processId."
      }
      [pscustomobject]@{
        ProcessId = $processId
        ExecutablePath = [System.IO.Path]::GetFullPath($livePath)
        SessionId = [int]$live.SessionId
      }
    }
  )
}

function Test-ExactPath {
  param(
    [AllowNull()][string]$Actual,
    [AllowNull()][string]$Expected
  )

  if (-not $Actual -or -not $Expected) { return $false }
  try {
    return [System.IO.Path]::GetFullPath($Actual).Equals(
      [System.IO.Path]::GetFullPath($Expected),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function Get-SsrvpnTunInterfaceIndexes {
  $indexes = @()
  $adapters = @(
    Get-NetAdapter -IncludeHidden -ErrorAction Stop |
      Where-Object { $_.Name -ceq 'Meta Tunnel' }
  )
  foreach ($adapter in $adapters) {
    $interfaceIndex = 0
    if ($null -eq $adapter.PSObject.Properties['ifIndex'] -or
        -not [int]::TryParse(
          [string]$adapter.ifIndex, [ref]$interfaceIndex) -or
        $interfaceIndex -le 0) {
      throw 'Meta Tunnel returned an invalid interface index.'
    }
    $indexes += $interfaceIndex
  }
  return @($indexes | Sort-Object -Unique)
}

function Test-SsrvpnTunArtifactsRemoved {
  param([Parameter(Mandatory = $true)][int[]]$InterfaceIndexes)

  $adapterIndexes = @(
    Get-NetAdapter -IncludeHidden -ErrorAction Stop |
      ForEach-Object { [int]$_.ifIndex }
  )
  $addressIndexes = @(
    Get-NetIPAddress -ErrorAction Stop |
      ForEach-Object { [int]$_.InterfaceIndex }
  )
  $routeIndexes = @(
    Get-NetRoute -ErrorAction Stop |
      ForEach-Object { [int]$_.InterfaceIndex }
  )
  foreach ($interfaceIndex in $InterfaceIndexes) {
    if (($adapterIndexes -contains $interfaceIndex) -or
        ($addressIndexes -contains $interfaceIndex) -or
        ($routeIndexes -contains $interfaceIndex)) {
      return $false
    }
  }
  return $true
}

function Wait-SsrvpnTunTeardown {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [int[]]$InterfaceIndexes,
    [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
  )

  if ($InterfaceIndexes.Count -eq 0) { return $true }
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  $lastProbeError = ''
  while ($true) {
    try {
      if (Test-SsrvpnTunArtifactsRemoved `
          -InterfaceIndexes $InterfaceIndexes) {
        return $true
      }
      $lastProbeError = ''
    } catch {
      $lastProbeError = $_.Exception.Message
    }

    $remaining = [int][Math]::Ceiling(
      ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
  }
  if ($lastProbeError) {
    Write-Warning "Could not confirm TUN teardown: $lastProbeError"
  }
  return $false
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class SsrvpnVerifiedProcessTerminator {
  private const uint ProcessTerminate = 0x0001;
  private const uint ProcessQueryLimitedInformation = 0x1000;
  private const uint Synchronize = 0x00100000;
  private const uint StillActive = 259;
  private const uint WaitObject0 = 0;
  private const uint WaitTimeout = 258;

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern IntPtr OpenProcess(
      uint desiredAccess, bool inheritHandle, uint processId);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint GetProcessId(IntPtr process);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool ProcessIdToSessionId(
      uint processId, out uint sessionId);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool QueryFullProcessImageNameW(
      IntPtr process, uint flags, StringBuilder imageName, ref uint size);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool GetExitCodeProcess(
      IntPtr process, out uint exitCode);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint WaitForSingleObject(
      IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool CloseHandle(IntPtr handle);

  // 0 = terminated, 1 = already gone, 2 = identity mismatch.
  public static int Terminate(
      uint expectedProcessId, string expectedPath, uint expectedSessionId) {
    IntPtr process = OpenProcess(
        ProcessQueryLimitedInformation | ProcessTerminate | Synchronize,
        false,
        expectedProcessId);
    if (process == IntPtr.Zero) {
      int error = Marshal.GetLastWin32Error();
      if (error == 87) return 1;
      throw new Win32Exception(error);
    }
    try {
      uint exitCode;
      if (GetExitCodeProcess(process, out exitCode) && exitCode != StillActive) {
        return 1;
      }
      uint liveProcessId = GetProcessId(process);
      if (liveProcessId == 0) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      uint liveSessionId;
      if (!ProcessIdToSessionId(liveProcessId, out liveSessionId)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      var imageName = new StringBuilder(32768);
      uint imageNameSize = (uint)imageName.Capacity;
      if (!QueryFullProcessImageNameW(
          process, 0, imageName, ref imageNameSize)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      if (liveProcessId != expectedProcessId ||
          liveSessionId != expectedSessionId ||
          !Path.GetFullPath(imageName.ToString()).Equals(
              Path.GetFullPath(expectedPath),
              StringComparison.OrdinalIgnoreCase)) {
        return 2;
      }
      if (!TerminateProcess(process, 1)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      uint waitResult = WaitForSingleObject(process, 8000);
      if (waitResult == WaitObject0) return 0;
      if (waitResult == WaitTimeout) {
        throw new TimeoutException("Timed out waiting for process termination.");
      }
      throw new Win32Exception(Marshal.GetLastWin32Error());
    } finally {
      CloseHandle(process);
    }
  }
}
'@

function Stop-VerifiedProcess {
  param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$ExpectedPath
  )

  $result = [SsrvpnVerifiedProcessTerminator]::Terminate(
    [uint32]$ProcessId,
    $ExpectedPath,
    [uint32]$currentSessionId
  )
  if ($result -eq 0 -or $result -eq 1) { return }
  throw "Process identity changed before terminating PID $ProcessId."
}

function Remove-ProxyRecoveryRunOnce {
  $runOncePath =
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  if (Test-Path -Path $runOncePath) {
    $runOnce = Get-ItemProperty -Path $runOncePath
    if ($null -ne $runOnce.PSObject.Properties['SSRVPNProxyRecovery']) {
      Remove-ItemProperty -Path $runOncePath -Name 'SSRVPNProxyRecovery' `
        -ErrorAction Stop
    }
  }
}

function Get-ValidatedExpectedPath {
  param(
    [AllowNull()][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedFileName
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or
      -not [System.IO.Path]::IsPathRooted($Path)) {
    throw "Expected executable path for $ExpectedFileName is empty or relative."
  }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
  } catch {
    throw "Expected executable path for $ExpectedFileName is invalid."
  }
  if (-not [System.IO.Path]::GetFileName($fullPath).Equals(
      $ExpectedFileName, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Expected executable path does not name $ExpectedFileName."
  }
  return $fullPath
}

function Remove-ProxyRecoveryState {
  $cleanupErrors = @()
  $jsonPath = Join-Path $env:LOCALAPPDATA `
    'SSRVPN\runtime\system_proxy_backup.json'
  $jsonExists = $false
  $jsonTerminal = $false
  try {
    $jsonExists = Test-Path -LiteralPath $jsonPath -PathType Leaf
    $jsonTerminal = -not $jsonExists
  } catch {
    $cleanupErrors += "Could not inspect JSON proxy recovery state: $($_.Exception.Message)"
  }
  if ($jsonExists) {
    $tempJsonPath = "$jsonPath.tmp"
    $terminalizeError = ''
    try {
      $json = Get-Content -LiteralPath $jsonPath -Encoding UTF8 -Raw |
        ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $json.PSObject.Properties['_activationInProgress']) {
        $json._activationInProgress = $false
      } else {
        $json | Add-Member -NotePropertyName '_activationInProgress' `
          -NotePropertyValue $false -ErrorAction Stop
      }
      $jsonText = $json | ConvertTo-Json -Compress -Depth 8
      [System.IO.File]::WriteAllText(
        $tempJsonPath,
        $jsonText,
        [System.Text.UTF8Encoding]::new($false)
      )
      Move-Item -LiteralPath $tempJsonPath -Destination $jsonPath -Force `
        -ErrorAction Stop
      $jsonTerminal = $true
    } catch {
      $terminalizeError = $_.Exception.Message
      try {
        if (Test-Path -LiteralPath $tempJsonPath -PathType Leaf) {
          Remove-Item -LiteralPath $tempJsonPath -Force -ErrorAction Stop
        }
      } catch {}
    }
    if (-not $jsonTerminal) {
      try {
        Remove-Item -LiteralPath $jsonPath -Force -ErrorAction Stop
        $jsonExists = $false
        $jsonTerminal = $true
      } catch {
        $cleanupErrors += "Could not terminalize or remove JSON proxy recovery state: $terminalizeError; $($_.Exception.Message)"
      }
    }
  }
  if (-not $jsonTerminal) {
    throw ($cleanupErrors -join '; ')
  }

  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  $nativeExists = $false
  $nativeInspected = $false
  try {
    $nativeExists = Test-Path -Path $nativePath
    $nativeInspected = $true
  } catch {
    $cleanupErrors += "Could not inspect native proxy recovery state: $($_.Exception.Message)"
  }
  $nativeTerminal = $nativeInspected -and -not $nativeExists
  if ($nativeExists) {
    $nativeErrors = @()
    # Make a surviving journal terminal before deletion. A later launcher or
    # RunOnce worker must not replay a completed restore over newer user state.
    try {
      Set-ItemProperty -Path $nativePath -Name 'Valid' -Type DWord -Value 0 `
        -ErrorAction Stop
      $nativeTerminal = $true
    } catch {
      $nativeErrors += "Could not invalidate native proxy recovery state: $($_.Exception.Message)"
    }
    $flagsTerminal = $true
    foreach ($entry in @(
      @{ Name = 'ActivationInProgress'; Value = 0 },
      @{ Name = 'RestoreInProgress'; Value = 0 },
      @{ Name = 'EndpointRestoreInProgress'; Value = 0 }
    )) {
      try {
        Set-ItemProperty -Path $nativePath -Name $entry.Name -Type DWord `
          -Value $entry.Value -ErrorAction Stop
      } catch {
        $flagsTerminal = $false
        $nativeErrors += "Could not invalidate native proxy recovery state: $($_.Exception.Message)"
      }
    }
    if ($flagsTerminal) { $nativeTerminal = $true }
    try {
      Remove-Item -Path $nativePath -Recurse -Force -ErrorAction Stop
      $nativeTerminal = $true
    } catch {
      $nativeErrors += "Could not remove native proxy recovery state: $($_.Exception.Message)"
    }
    if (-not $nativeTerminal) { $cleanupErrors += $nativeErrors }
  }
  if (-not $nativeTerminal) {
    throw ($cleanupErrors -join '; ')
  }
  if ($jsonExists) {
    try {
      if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        Remove-Item -LiteralPath $jsonPath -Force -ErrorAction Stop
      }
    } catch {
      $cleanupErrors += "Could not remove JSON proxy recovery state: $($_.Exception.Message)"
    }
  }
  try {
    Remove-ProxyRecoveryRunOnce
  } catch {
    $cleanupErrors += "Could not remove proxy recovery RunOnce: $($_.Exception.Message)"
  }
  if ($cleanupErrors.Count -gt 0) {
    throw ($cleanupErrors -join '; ')
  }
}

function Test-RequiredProperties {
  param(
    [AllowNull()]$Value,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  if ($null -eq $Value) { return $false }
  foreach ($name in $Names) {
    if ($null -eq $Value.PSObject.Properties[$name]) { return $false }
  }
  return $true
}

function Test-OwnedProxyServer {
  param([AllowNull()][string]$Value)

  if (-not $Value -or $Value -notmatch '^127\.0\.0\.1:([0-9]{1,5})$') {
    return $false
  }
  $port = [int]$matches[1]
  return $port -ge 1 -and $port -le 65535
}

function Test-DwordFlag {
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $false }
  if ($Value -isnot [int32] -and $Value -isnot [uint32]) { return $false }
  return $Value -eq 0 -or $Value -eq 1
}

function Test-BooleanValue {
  param([AllowNull()]$Value)

  return $null -ne $Value -and $Value -is [bool]
}

function Test-NativeRecoveryJournalNonReplayable {
  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  if (-not (Test-Path -Path $nativePath)) { return $true }

  $native = Get-ItemProperty -Path $nativePath
  if (-not (Test-RequiredProperties -Value $native -Names @('Valid'))) {
    return $false
  }
  if (-not (Test-DwordFlag -Value $native.Valid)) { return $false }
  if ([int]$native.Valid -eq 0) { return $true }

  $pendingNames = @(
    'RestoreInProgress', 'ActivationInProgress',
    'EndpointRestoreInProgress'
  )
  if (-not (Test-RequiredProperties -Value $native -Names $pendingNames)) {
    return $false
  }
  foreach ($name in $pendingNames) {
    if (-not (Test-DwordFlag -Value $native.$name)) { return $false }
    if ([int]$native.$name -eq 1) { return $false }
  }
  return $true
}

function Test-JsonActivationCorroboratedByNative {
  param(
    [AllowNull()]$Native,
    [AllowNull()]$Json
  )

  $required = @(
    'Valid', 'OwnedProxyServer', 'OwnedProxyOverride',
    'RestoreInProgress', 'ActivationInProgress',
    'EndpointRestoreInProgress'
  )
  if (-not (Test-RequiredProperties -Value $Native -Names $required) -or
      -not (Test-RequiredProperties -Value $Json -Names @(
        '_ownedProxyServer', '_activationInProgress'
      ))) {
    return $false
  }
  foreach ($name in @(
    'Valid', 'RestoreInProgress', 'ActivationInProgress',
    'EndpointRestoreInProgress'
  )) {
    if (-not (Test-DwordFlag -Value $Native.$name)) { return $false }
  }
  if (-not (Test-BooleanValue -Value $Json._activationInProgress) -or
      -not [bool]$Json._activationInProgress -or
      [int]$Native.Valid -ne 1 -or
      $Native.OwnedProxyServer -isnot [string] -or
      $Native.OwnedProxyOverride -isnot [string] -or
      $Json._ownedProxyServer -isnot [string] -or
      [string]$Native.OwnedProxyServer -ne [string]$Json._ownedProxyServer -or
      [string]$Native.OwnedProxyOverride -ne $script:OwnedProxyOverride) {
    return $false
  }
  return [int]$Native.RestoreInProgress -eq 1 -or
    [int]$Native.ActivationInProgress -eq 1 -or
    [int]$Native.EndpointRestoreInProgress -eq 1
}

function Test-RecoveryState {
  param([AllowNull()]$Value)

  try {
    if (-not (Test-RequiredProperties -Value $Value -Names @(
      'proxyEnable', 'hasProxyServer', 'proxyServer',
      'hasProxyOverride', 'proxyOverride', 'hasAutoConfigUrl',
      'autoConfigUrl', 'hasAutoDetect', 'autoDetect',
      'ownedProxyServer', 'ownedProxyOverride', 'restoreInProgress',
      'activationInProgress', 'endpointRestoreInProgress'
    ))) { return $false }
    if (-not (Test-OwnedProxyServer -Value $Value.ownedProxyServer)) {
      return $false
    }
    if ([string]$Value.ownedProxyOverride -ne $script:OwnedProxyOverride) {
      return $false
    }
    if (-not (Test-DwordFlag -Value $Value.proxyEnable) -or
        -not (Test-DwordFlag -Value $Value.autoDetect)) {
      return $false
    }
    foreach ($name in @(
      'hasProxyEnable', 'hasProxyServer', 'hasProxyOverride', 'hasAutoConfigUrl',
      'hasAutoDetect', 'restoreInProgress', 'activationInProgress',
      'endpointRestoreInProgress'
    )) {
      if (-not (Test-BooleanValue -Value $Value.$name)) { return $false }
    }
    return $true
  } catch {
    return $false
  }
}

function Get-ProxyRecoveryState {
  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  $native = $null
  if (Test-Path -Path $nativePath) {
    $native = Get-ItemProperty -Path $nativePath
    $hasNativeFields = Test-RequiredProperties -Value $native -Names @(
      'Valid', 'OriginalProxyEnable', 'HasProxyServer',
      'OriginalProxyServer', 'HasProxyOverride', 'OriginalProxyOverride',
      'HasAutoConfigURL', 'OriginalAutoConfigURL', 'HasAutoDetect',
      'OriginalAutoDetect', 'OwnedProxyServer', 'OwnedProxyOverride'
    )
    $nativeFlagNames = @(
      'Valid', 'OriginalProxyEnable', 'HasProxyServer', 'HasProxyOverride',
      'HasAutoConfigURL', 'HasAutoDetect', 'OriginalAutoDetect'
    )
    if ($null -ne $native.PSObject.Properties['HasProxyEnable']) { $nativeFlagNames += 'HasProxyEnable' }
    $nativeFlagsValid = $hasNativeFields
    foreach ($name in $nativeFlagNames) {
      if (-not (Test-DwordFlag -Value $native.$name)) {
        $nativeFlagsValid = $false
      }
    }
    foreach ($name in @(
      'RestoreInProgress', 'ActivationInProgress',
      'EndpointRestoreInProgress'
    )) {
      if ($null -ne $native.PSObject.Properties[$name] -and
          -not (Test-DwordFlag -Value $native.$name)) {
        $nativeFlagsValid = $false
      }
    }
    if ($nativeFlagsValid -and [int]$native.Valid -eq 1) {
      $candidate = [pscustomobject]@{
        hasProxyEnable = $null -eq $native.PSObject.Properties['HasProxyEnable'] -or [int]$native.HasProxyEnable -ne 0
        proxyEnable = [int]$native.OriginalProxyEnable
        hasProxyServer = [int]$native.HasProxyServer -ne 0
        proxyServer = [string]$native.OriginalProxyServer
        hasProxyOverride = [int]$native.HasProxyOverride -ne 0
        proxyOverride = [string]$native.OriginalProxyOverride
        hasAutoConfigUrl = [int]$native.HasAutoConfigURL -ne 0
        autoConfigUrl = [string]$native.OriginalAutoConfigURL
        hasAutoDetect = [int]$native.HasAutoDetect -ne 0
        autoDetect = [int]$native.OriginalAutoDetect
        ownedProxyServer = [string]$native.OwnedProxyServer
        ownedProxyOverride = [string]$native.OwnedProxyOverride
        restoreInProgress =
          $null -ne $native.PSObject.Properties['RestoreInProgress'] -and
          [int]$native.RestoreInProgress -eq 1
        activationInProgress =
          $null -ne $native.PSObject.Properties['ActivationInProgress'] -and
          [int]$native.ActivationInProgress -eq 1
        endpointRestoreInProgress =
          $null -ne $native.PSObject.Properties['EndpointRestoreInProgress'] -and
          [int]$native.EndpointRestoreInProgress -eq 1
      }
      if (Test-RecoveryState -Value $candidate) { return $candidate }
    }
  }

  if (-not $env:LOCALAPPDATA) { return $null }
  $jsonPath = Join-Path $env:LOCALAPPDATA `
    'SSRVPN\runtime\system_proxy_backup.json'
  if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
    return $null
  }
  try {
    $json = Get-Content -LiteralPath $jsonPath -Encoding UTF8 -Raw |
      ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not (Test-RequiredProperties -Value $json -Names @(
    'proxyEnable', 'hasProxyServer', 'proxyServer',
    'hasProxyOverride', 'proxyOverride', 'hasAutoConfigUrl',
    'autoConfigUrl', 'hasAutoDetect', 'autoDetect',
    '_ownedProxyServer', '_activationInProgress'
  ))) { return $null }
  if (-not (Test-DwordFlag -Value $json.proxyEnable) -or
      -not (Test-DwordFlag -Value $json.autoDetect)) {
    return $null
  }
  $jsonBooleanNames = @(
    'hasProxyServer', 'hasProxyOverride', 'hasAutoConfigUrl',
    'hasAutoDetect', '_activationInProgress'
  )
  if ($null -ne $json.PSObject.Properties['hasProxyEnable']) {
    $jsonBooleanNames += 'hasProxyEnable'
  }
  foreach ($name in $jsonBooleanNames) {
    if (-not (Test-BooleanValue -Value $json.$name)) { return $null }
  }
  $candidate = [pscustomobject]@{
    hasProxyEnable = $null -eq $json.PSObject.Properties['hasProxyEnable'] -or [bool]$json.hasProxyEnable
    proxyEnable = [int]$json.proxyEnable
    hasProxyServer = [bool]$json.hasProxyServer
    proxyServer = [string]$json.proxyServer
    hasProxyOverride = [bool]$json.hasProxyOverride
    proxyOverride = [string]$json.proxyOverride
    hasAutoConfigUrl = [bool]$json.hasAutoConfigUrl
    autoConfigUrl = [string]$json.autoConfigUrl
    hasAutoDetect = [bool]$json.hasAutoDetect
    autoDetect = [int]$json.autoDetect
    ownedProxyServer = [string]$json._ownedProxyServer
    ownedProxyOverride = $script:OwnedProxyOverride
    restoreInProgress = $false
    activationInProgress = (Test-JsonActivationCorroboratedByNative `
      -Native $native -Json $json)
    endpointRestoreInProgress = $false
  }
  if (Test-RecoveryState -Value $candidate) { return $candidate }
  return $null
}

function Write-NativeRestoreJournal {
  param(
    [Parameter(Mandatory = $true)]$Backup,
    [switch]$EndpointOnly
  )

  $path = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  New-Item -Path $path -Force | Out-Null
  Set-ItemProperty -Path $path -Name Valid -Type DWord -Value 0
  $values = @{
    HasProxyEnable = [int][bool]$Backup.hasProxyEnable
    OriginalProxyEnable = [int]$Backup.proxyEnable
    HasProxyServer = [int][bool]$Backup.hasProxyServer
    OriginalProxyServer = [string]$Backup.proxyServer
    HasProxyOverride = [int][bool]$Backup.hasProxyOverride
    OriginalProxyOverride = [string]$Backup.proxyOverride
    HasAutoConfigURL = [int][bool]$Backup.hasAutoConfigUrl
    OriginalAutoConfigURL = [string]$Backup.autoConfigUrl
    HasAutoDetect = [int][bool]$Backup.hasAutoDetect
    OriginalAutoDetect = [int]$Backup.autoDetect
    OwnedProxyServer = [string]$Backup.ownedProxyServer
    OwnedProxyOverride = [string]$Backup.ownedProxyOverride
    RestoreInProgress = [int](-not [bool]$EndpointOnly)
    EndpointRestoreInProgress = [int][bool]$EndpointOnly
    ActivationInProgress = 0
  }
  foreach ($entry in $values.GetEnumerator()) {
    $type = if ($entry.Value -is [int]) { 'DWord' } else { 'String' }
    Set-ItemProperty -Path $path -Name $entry.Key -Type $type `
      -Value $entry.Value
  }
  Set-ItemProperty -Path $path -Name Valid -Type DWord -Value 1
}

function Complete-NativeRestoreJournal {
  $path = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  $errors = @()
  $terminal = $false
  try {
    Set-ItemProperty -Path $path -Name Valid -Type DWord -Value 0 `
      -ErrorAction Stop
    $terminal = $true
  } catch {
    $errors += $_.Exception.Message
  }

  $flagsTerminal = $true
  foreach ($name in @(
    'RestoreInProgress',
    'EndpointRestoreInProgress',
    'ActivationInProgress'
  )) {
    try {
      Set-ItemProperty -Path $path -Name $name -Type DWord -Value 0 `
        -ErrorAction Stop
    } catch {
      $flagsTerminal = $false
      $errors += $_.Exception.Message
    }
  }
  if ($flagsTerminal) { $terminal = $true }

  $removed = $false
  try {
    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
    $removed = $true
  } catch {
    $errors += $_.Exception.Message
  }
  if (-not ($terminal -or $removed)) {
    throw ('Could not terminalize native proxy recovery state: ' +
      ($errors -join '; '))
  }
}

function Notify-WinInetProxyChange {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SsrVpnInstallerWinInet {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
"@
  [SsrVpnInstallerWinInet]::InternetSetOption(
    [IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [SsrVpnInstallerWinInet]::InternetSetOption(
    [IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Repair-InvalidProxyRecoveryState {
  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  $jsonPath = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'SSRVPN\runtime\system_proxy_backup.json'
  } else {
    $null
  }
  $hasRecoveryState = (Test-Path -Path $nativePath) -or
    ($jsonPath -and (Test-Path -LiteralPath $jsonPath -PathType Leaf))
  if (-not $hasRecoveryState) {
    Remove-ProxyRecoveryRunOnce
    return
  }

  $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $current = Get-ItemProperty -Path $regPath
  $hasProxyServer = $null -ne $current.PSObject.Properties['ProxyServer']
  $hasProxyOverride = $null -ne $current.PSObject.Properties['ProxyOverride']
  $hasAutoDetect = $null -ne $current.PSObject.Properties['AutoDetect']
  $hasAutoConfigUrl = $null -ne $current.PSObject.Properties['AutoConfigURL']
  $autoDetectDisabled = -not $hasAutoDetect -or
    ((Test-DwordFlag -Value $current.AutoDetect) -and
      [int]$current.AutoDetect -eq 0)
  $proxyEnabled = (Test-DwordFlag -Value $current.ProxyEnable) -and
    [int]$current.ProxyEnable -eq 1
  $ownedFingerprint = $proxyEnabled -and
    $hasProxyServer -and
    (Test-OwnedProxyServer -Value ([string]$current.ProxyServer)) -and
    $hasProxyOverride -and
    [string]$current.ProxyOverride -eq $script:OwnedProxyOverride -and
    $autoDetectDisabled -and
    -not $hasAutoConfigUrl
  if ($ownedFingerprint) {
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 0
    Notify-WinInetProxyChange
  }
  Remove-ProxyRecoveryState
}

function Restore-OwnedSystemProxy {
  $backup = Get-ProxyRecoveryState
  if (-not $backup) {
    Repair-InvalidProxyRecoveryState
    return
  }

  $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $current = Get-ItemProperty -Path $regPath
  $hasProxyServer = $null -ne $current.PSObject.Properties['ProxyServer']
  $hasProxyOverride = $null -ne $current.PSObject.Properties['ProxyOverride']
  $hasAutoDetect = $null -ne $current.PSObject.Properties['AutoDetect']
  $hasAutoConfigUrl = $null -ne $current.PSObject.Properties['AutoConfigURL']
  $autoDetectDisabled = -not $hasAutoDetect -or
    ((Test-DwordFlag -Value $current.AutoDetect) -and
      [int]$current.AutoDetect -eq 0)
  $proxyEnabled = (Test-DwordFlag -Value $current.ProxyEnable) -and
    [int]$current.ProxyEnable -eq 1
  $owned = $proxyEnabled -and
    $hasProxyServer -and [string]$current.ProxyServer -eq $backup.ownedProxyServer -and
    $hasProxyOverride -and [string]$current.ProxyOverride -eq $backup.ownedProxyOverride -and
    $autoDetectDisabled -and
    -not $hasAutoConfigUrl
  $endpointOwned = $proxyEnabled -and
    $hasProxyServer -and
    [string]$current.ProxyServer -eq $backup.ownedProxyServer
  $currentState = Get-SystemProxyState -Value $current
  $ownedState = [pscustomobject]@{
    hasProxyEnable = $true
    proxyEnable = 1
    hasProxyServer = $true
    proxyServer = [string]$backup.ownedProxyServer
    hasProxyOverride = $true
    proxyOverride = [string]$backup.ownedProxyOverride
    hasAutoConfigUrl = $false
    autoConfigUrl = ''
    hasAutoDetect = $true
    autoDetect = 0
  }
  $activationPrefix = [bool]$backup.activationInProgress -and
    -not [bool]$backup.restoreInProgress -and
    -not [bool]$backup.endpointRestoreInProgress -and
    (Test-ReachableProxyTransactionState -Current $currentState `
      -Original $backup -Owned $ownedState -Phase Activation)
  $fullRestorePrefix = [bool]$backup.restoreInProgress -and
    -not [bool]$backup.endpointRestoreInProgress -and
    (Test-ReachableProxyTransactionState -Current $currentState `
      -Original $backup -Owned $ownedState -Phase FullRestore)
  $endpointRestorePrefix = [bool]$backup.endpointRestoreInProgress -and
    -not [bool]$backup.restoreInProgress -and
    (Test-ReachableProxyTransactionState -Current $currentState `
      -Original $backup -Owned $ownedState -Phase EndpointRestore)
  $restoreFull = $owned -or $activationPrefix -or $fullRestorePrefix
  $restoreEndpoint = (-not $restoreFull -and $endpointOwned) -or
    $endpointRestorePrefix
  if ($restoreEndpoint) {
    Write-NativeRestoreJournal -Backup $backup -EndpointOnly
    if (-not [bool]$backup.hasProxyEnable -or
        [int]$backup.proxyEnable -eq 0) {
      Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 0
    }
    Set-OrRemoveRegistryValue -Path $regPath -Name ProxyServer `
      -Present $backup.hasProxyServer -Value $backup.proxyServer
    Set-OrRemoveRegistryValue -Path $regPath -Name ProxyEnable `
      -Present ([bool]$backup.hasProxyEnable) `
      -Value ([string]$backup.proxyEnable) -Type DWord
    Complete-NativeRestoreJournal
    Notify-WinInetProxyChange
    Remove-ProxyRecoveryState
    return
  }
  if (-not $restoreFull) {
    Remove-ProxyRecoveryState
    return
  }

  # Persist a resumable journal before the first Internet Settings write. A
  # power loss or registry error can then continue the exact original restore
  # instead of losing the only known-good snapshot.
  Write-NativeRestoreJournal -Backup $backup

  # A disabled original proxy becomes safe before any supporting value write.
  if (-not [bool]$backup.hasProxyEnable -or
      [int]$backup.proxyEnable -eq 0) {
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 0
  }
  Set-OrRemoveRegistryValue -Path $regPath -Name ProxyServer `
    -Present $backup.hasProxyServer -Value $backup.proxyServer
  Set-OrRemoveRegistryValue -Path $regPath -Name ProxyOverride `
    -Present $backup.hasProxyOverride -Value $backup.proxyOverride
  Set-OrRemoveRegistryValue -Path $regPath -Name AutoConfigURL `
    -Present $backup.hasAutoConfigUrl -Value $backup.autoConfigUrl
  Set-OrRemoveRegistryValue -Path $regPath -Name AutoDetect `
    -Present $backup.hasAutoDetect -Value ([string]$backup.autoDetect) -Type DWord
  Set-OrRemoveRegistryValue -Path $regPath -Name ProxyEnable `
    -Present ([bool]$backup.hasProxyEnable) `
    -Value ([string]$backup.proxyEnable) -Type DWord
  Complete-NativeRestoreJournal

  Notify-WinInetProxyChange
  Remove-ProxyRecoveryState
}

function Disable-OwnedSystemProxyEndpoint {
  param([AllowNull()]$Backup)

  $backup = if ($null -ne $Backup) { $Backup } else {
    Get-ProxyRecoveryState
  }
  if (-not $backup) { return }

  $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $current = Get-ItemProperty -Path $regPath
  $hasProxyServer = $null -ne $current.PSObject.Properties['ProxyServer']
  $proxyEnabled = (Test-DwordFlag -Value $current.ProxyEnable) -and
    [int]$current.ProxyEnable -eq 1
  if ($proxyEnabled -and
      $hasProxyServer -and
      [string]$current.ProxyServer -eq [string]$backup.ownedProxyServer) {
    # Keep the recovery journal so the next SSRVPN launch can still restore the
    # exact original settings. Disabling only the dead endpoint prevents an
    # interrupted upgrade from leaving the user offline.
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 0
    Notify-WinInetProxyChange
  }
}

function Test-SystemProxySafeToStop {
  param(
    [AllowNull()]$Backup,
    [bool]$InstalledProcessRunning
  )

  try {
    $regPath =
      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $current = Get-ItemProperty -Path $regPath
    if ($null -eq $current.PSObject.Properties['ProxyEnable']) {
      return $true
    }
    if (-not (Test-DwordFlag -Value $current.ProxyEnable)) {
      return $false
    }
    if ([int]$current.ProxyEnable -eq 0) { return $true }
    if (-not (Test-NativeRecoveryJournalNonReplayable)) { return $false }
    if ([int]$current.ProxyEnable -ne 1) { return $false }

    $hasProxyServer = $null -ne $current.PSObject.Properties['ProxyServer']
    if (-not $hasProxyServer) { return $false }
    $proxyServer = [string]$current.ProxyServer
    if ($Backup -and $proxyServer -eq [string]$Backup.ownedProxyServer) {
      return $false
    }
    if (-not $Backup -and $InstalledProcessRunning -and
        (Test-OwnedProxyServer -Value $proxyServer)) {
      return $false
    }

    $hasProxyOverride =
      $null -ne $current.PSObject.Properties['ProxyOverride']
    $hasAutoDetect = $null -ne $current.PSObject.Properties['AutoDetect']
    $hasAutoConfigUrl =
      $null -ne $current.PSObject.Properties['AutoConfigURL']
    $autoDetectDisabled =
      -not $hasAutoDetect -or
      ((Test-DwordFlag -Value $current.AutoDetect) -and
        [int]$current.AutoDetect -eq 0)
    $ownedFingerprint =
      (Test-OwnedProxyServer -Value $proxyServer) -and
      $hasProxyOverride -and
      [string]$current.ProxyOverride -eq $script:OwnedProxyOverride -and
      $autoDetectDisabled -and
      -not $hasAutoConfigUrl
    return -not $ownedFingerprint
  } catch {
    Write-Warning "Could not verify the current system proxy: $($_.Exception.Message)"
    return $false
  }
}

$apps = @()
$launchers = @()
$cores = @()
$proxyRecoveryFailed = $false
try {
  $InstalledAppPath = Get-ValidatedExpectedPath -Path $InstalledAppPath `
    -ExpectedFileName 'ssrvpn_windows_app.exe'
  $InstalledLauncherPath = Get-ValidatedExpectedPath `
    -Path $InstalledLauncherPath -ExpectedFileName 'ssrvpn_windows.exe'
  $InstalledCorePath = Get-ValidatedExpectedPath -Path $InstalledCorePath `
    -ExpectedFileName 'mihomo.exe'
  $installRoot = [System.IO.Path]::GetDirectoryName($InstalledLauncherPath)
  if (-not (Test-ExactPath -Actual $InstalledAppPath -Expected (
        Join-Path $installRoot 'bin\ssrvpn_windows_app.exe')) -or
      -not (Test-ExactPath -Actual $InstalledCorePath -Expected (
        Join-Path $installRoot 'bin\mihomo.exe'))) {
    throw 'Installed executable paths do not describe one SSRVPN installation.'
  }

  $apps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
  $launchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
  $cores = @(Get-ProcessesByName -Name 'mihomo.exe')
} catch {
  Set-StopStatus -Status 'IDENTITY_UNVERIFIED'
  Write-Warning "Could not enumerate SSRVPN app processes: $($_.Exception.Message)"
  exit 3
}

$installedApps = @(
  $apps |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledAppPath
    }
)
$installedLaunchers = @(
  $launchers |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledLauncherPath
    }
)
$installedCoresBefore = @(
  $cores |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledCorePath
    }
)
$foreignApps = @($apps | Where-Object {
  -not (Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledAppPath)
})
$foreignLaunchers = @($launchers | Where-Object {
  -not (Test-ExactPath -Actual $_.ExecutablePath `
    -Expected $InstalledLauncherPath)
})
$foreignCores = @($cores | Where-Object {
  -not (Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledCorePath)
})
if ($foreignApps.Count -gt 0 -or
    $foreignLaunchers.Count -gt 0 -or
    $foreignCores.Count -gt 0) {
  Set-StopStatus -Status 'FOREIGN_INSTANCE'
  Write-Warning 'Another SSRVPN or same-name core instance is active; refusing global proxy recovery.'
  exit 3
}

$installedProcessRunning =
  $installedApps.Count -gt 0 -or
  $installedLaunchers.Count -gt 0 -or
  $installedCoresBefore.Count -gt 0
$tunInterfaceIndexes = @()
try {
  $tunInterfaceIndexes = @(Get-SsrvpnTunInterfaceIndexes)
} catch {
  if ($installedProcessRunning) {
    Set-StopStatus -Status 'TUN_TEARDOWN_PENDING'
    Write-Warning "Could not capture SSRVPN TUN ownership before stopping processes: $($_.Exception.Message)"
    exit 3
  }
  Write-Warning "Could not inspect stale SSRVPN TUN state: $($_.Exception.Message)"
}
$proxyBackup = Get-ProxyRecoveryState
foreach ($app in $installedApps) {
  try {
    Stop-VerifiedProcess -ProcessId ([int]$app.ProcessId) `
      -ExpectedPath $InstalledAppPath
  } catch {
    Write-Warning "Could not stop SSRVPN app PID $($app.ProcessId)."
  }
}

# Do not alter WinINet until every visible app process is gone. If a force-stop
# is denied, the still-running app/core/proxy combination remains internally
# consistent and the installer can abort without creating silent direct mode.
Start-Sleep -Milliseconds 300
$appsBeforeRecovery = @(
  Get-ProcessesByName -Name 'ssrvpn_windows_app.exe' |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledAppPath
    }
)
if ($appsBeforeRecovery.Count -gt 0) {
  Set-StopStatus -Status 'APP_STILL_RUNNING'
  Write-Warning 'SSRVPN app is still running; system proxy was left unchanged.'
  exit 2
}

try {
  Restore-OwnedSystemProxy
} catch {
  Write-Warning "Exact system-proxy restore failed: $($_.Exception.Message)"
  $proxyRecoveryFailed = $true
  try {
    Disable-OwnedSystemProxyEndpoint -Backup $proxyBackup
  } catch {
    Write-Warning "Could not disable the owned proxy endpoint: $($_.Exception.Message)"
    $proxyRecoveryFailed = $true
  }
}

if (-not (Test-SystemProxySafeToStop -Backup $proxyBackup `
      -InstalledProcessRunning $installedProcessRunning)) {
  try {
    Disable-OwnedSystemProxyEndpoint -Backup $proxyBackup
  } catch {
    $proxyRecoveryFailed = $true
    Write-Warning "Could not disable the captured SSRVPN proxy endpoint: $($_.Exception.Message)"
  }
  if (-not (Test-SystemProxySafeToStop -Backup $proxyBackup `
        -InstalledProcessRunning $installedProcessRunning)) {
    Set-StopStatus -Status 'PROXY_UNSAFE'
    Write-Warning 'Proxy recovery is not safe; the still-live core was retained.'
    exit 3
  }
}

foreach ($launcher in $installedLaunchers) {
  try {
    Stop-VerifiedProcess -ProcessId ([int]$launcher.ProcessId) `
      -ExpectedPath $InstalledLauncherPath
  } catch {
    Write-Warning "Could not stop SSRVPN launcher PID $($launcher.ProcessId)."
  }
}

Start-Sleep -Milliseconds 400

# Every mihomo process whose executable is the exact file being replaced belongs
# to this installation. Stopping all such PIDs prevents duplicate cores after an
# upgrade while leaving same-name cores from other products and portable copies
# untouched.
$installedCores = @(
  Get-ProcessesByName -Name 'mihomo.exe' |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledCorePath
    }
)
foreach ($core in $installedCores) {
  try {
    Stop-VerifiedProcess -ProcessId ([int]$core.ProcessId) `
      -ExpectedPath $InstalledCorePath
  } catch {
    Write-Warning "Could not stop installed mihomo PID $($core.ProcessId)."
  }
}

Start-Sleep -Milliseconds 300

$remainingApps = @(
  Get-ProcessesByName -Name 'ssrvpn_windows_app.exe' |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledAppPath
    }
)
$remainingLaunchers = @(
  Get-ProcessesByName -Name 'ssrvpn_windows.exe' |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledLauncherPath
    }
)
$remainingCores = @(
  Get-ProcessesByName -Name 'mihomo.exe' |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledCorePath
    }
)
if ($remainingApps.Count -gt 0 -or
    $remainingLaunchers.Count -gt 0 -or
    $remainingCores.Count -gt 0) {
  Set-StopStatus -Status 'PROCESSES_STILL_RUNNING'
  Write-Warning 'SSRVPN files are still in use; refusing a partial overwrite.'
  exit 2
}

try {
  $tunInterfaceIndexes += @(Get-SsrvpnTunInterfaceIndexes)
  $tunInterfaceIndexes = @($tunInterfaceIndexes | Sort-Object -Unique)
} catch {
  Set-StopStatus -Status 'TUN_TEARDOWN_PENDING'
  Write-Warning "Could not capture SSRVPN TUN ownership after stopping processes: $($_.Exception.Message)"
  exit 3
}

if (-not (Wait-SsrvpnTunTeardown `
    -InterfaceIndexes $tunInterfaceIndexes `
    -TimeoutMilliseconds $TunTeardownTimeoutMilliseconds)) {
  Set-StopStatus -Status 'TUN_TEARDOWN_PENDING'
  Write-Warning 'SSRVPN TUN adapter, addresses, or routes are still present; refusing file changes.'
  exit 3
}

if ($InstalledCorePidPath) {
  Remove-Item -LiteralPath $InstalledCorePidPath -Force `
    -ErrorAction SilentlyContinue
}

if ($proxyRecoveryFailed) {
  if ($RequireRecoveryCleanup) {
    Set-StopStatus -Status 'RECOVERY_CLEANUP_PENDING'
    Write-Warning 'Proxy endpoint is safe, but uninstall cannot remove the recovery helper while recovery artifacts remain.'
    exit 3
  }
  Write-Warning 'Proxy endpoint is safe, but recovery artifacts remain for the installed app to retry.'
}

Set-StopStatus -Status 'OK'
exit 0
