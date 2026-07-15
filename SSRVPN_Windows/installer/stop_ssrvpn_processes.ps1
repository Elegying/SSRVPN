param(
  [string]$InstalledAppPath = '',
  [string]$InstalledLauncherPath = '',
  [string]$InstalledCorePath = '',
  [string]$InstalledCorePidPath = ''
)

$ErrorActionPreference = 'Stop'
$currentSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
$script:OwnedProxyOverride = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;' +
  '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;' +
  '172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;' +
  '192.168.*'

function Get-ProcessesByName {
  param([Parameter(Mandatory = $true)][string]$Name)

  try {
    return @(
      Get-CimInstance -ClassName Win32_Process -Filter "Name = '$Name'" `
        -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $currentSessionId }
    )
  } catch {
    $cimError = $_.Exception.Message
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    try {
      return @(
        Get-Process -ErrorAction Stop |
          Where-Object {
            $_.ProcessName -ieq $processName -and
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

function Remove-ProxyRecoveryState {
  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  if (Test-Path -Path $nativePath) {
    Remove-Item -Path $nativePath -Recurse -Force
  }
  if ($env:LOCALAPPDATA) {
    $jsonPath = Join-Path $env:LOCALAPPDATA `
      'SSRVPN\runtime\system_proxy_backup.json'
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
      Remove-Item -LiteralPath $jsonPath -Force
    }
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
      'hasProxyServer', 'hasProxyOverride', 'hasAutoConfigUrl',
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
  foreach ($name in $jsonBooleanNames) {
    if (-not (Test-BooleanValue -Value $json.$name)) { return $null }
  }
  $candidate = [pscustomobject]@{
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
    activationInProgress = [bool]$json._activationInProgress
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
  if (-not $hasRecoveryState) { return }

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

function Set-OrRemoveRegistryValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Present,
    [AllowEmptyString()][string]$Value = '',
    [ValidateSet('String', 'DWord')][string]$Type = 'String'
  )

  if ($Present) {
    Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value
  } else {
    $current = Get-ItemProperty -Path $Path
    if ($null -ne $current.PSObject.Properties[$Name]) {
      Remove-ItemProperty -Path $Path -Name $Name
    }
  }
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
  if (-not $owned -and
      -not $backup.restoreInProgress -and
      -not $backup.activationInProgress -and
      ($endpointOwned -or $backup.endpointRestoreInProgress)) {
    Write-NativeRestoreJournal -Backup $backup -EndpointOnly
    Set-OrRemoveRegistryValue -Path $regPath -Name ProxyServer `
      -Present $backup.hasProxyServer -Value $backup.proxyServer
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord `
      -Value ([int]$backup.proxyEnable)
    Notify-WinInetProxyChange
    Remove-ProxyRecoveryState
    return
  }
  if (-not $owned -and
      -not $backup.restoreInProgress -and
      -not $backup.activationInProgress) {
    Remove-ProxyRecoveryState
    return
  }

  # Persist a resumable journal before the first Internet Settings write. A
  # power loss or registry error can then continue the exact original restore
  # instead of losing the only known-good snapshot.
  Write-NativeRestoreJournal -Backup $backup

  # Restore supporting values first and commit ProxyEnable last. If any write
  # fails, the outer best-effort handler disables only SSRVPN's owned endpoint.
  Set-OrRemoveRegistryValue -Path $regPath -Name ProxyServer `
    -Present $backup.hasProxyServer -Value $backup.proxyServer
  Set-OrRemoveRegistryValue -Path $regPath -Name ProxyOverride `
    -Present $backup.hasProxyOverride -Value $backup.proxyOverride
  Set-OrRemoveRegistryValue -Path $regPath -Name AutoConfigURL `
    -Present $backup.hasAutoConfigUrl -Value $backup.autoConfigUrl
  Set-OrRemoveRegistryValue -Path $regPath -Name AutoDetect `
    -Present $backup.hasAutoDetect -Value ([string]$backup.autoDetect) -Type DWord
  Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord `
    -Value ([int]$backup.proxyEnable)

  Notify-WinInetProxyChange
  Remove-ProxyRecoveryState
}

function Disable-OwnedSystemProxyEndpoint {
  $backup = Get-ProxyRecoveryState
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
    if ($null -eq $current.PSObject.Properties['ProxyEnable'] -or
        -not (Test-DwordFlag -Value $current.ProxyEnable)) {
      return $false
    }
    if ([int]$current.ProxyEnable -eq 0) { return $true }

    $hasProxyServer = $null -ne $current.PSObject.Properties['ProxyServer']
    if (-not $hasProxyServer) { return $true }
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
$proxyRecoveryFailed = $false
try {
  $apps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
  $launchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
} catch {
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

try {
  $installedCoresBefore = @(
    Get-ProcessesByName -Name 'mihomo.exe' |
      Where-Object {
        Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledCorePath
      }
  )
} catch {
  Write-Warning "Could not enumerate SSRVPN core processes: $($_.Exception.Message)"
  exit 3
}

$installedProcessRunning =
  $installedApps.Count -gt 0 -or
  $installedLaunchers.Count -gt 0 -or
  $installedCoresBefore.Count -gt 0
$proxyBackup = Get-ProxyRecoveryState
try {
  Restore-OwnedSystemProxy
} catch {
  Write-Warning "Exact system-proxy restore failed: $($_.Exception.Message)"
  try {
    Disable-OwnedSystemProxyEndpoint
  } catch {
    Write-Warning "Could not disable the owned proxy endpoint: $($_.Exception.Message)"
    $proxyRecoveryFailed = $true
  }
}

if ($proxyRecoveryFailed -or
    -not (Test-SystemProxySafeToStop -Backup $proxyBackup `
      -InstalledProcessRunning $installedProcessRunning)) {
  Write-Warning 'Proxy recovery failed; refusing to stop SSRVPN processes.'
  exit 3
}

$taskkill = if ($env:SystemRoot) {
  Join-Path $env:SystemRoot 'System32\taskkill.exe'
} else {
  $null
}
foreach ($app in $installedApps) {
  try {
    if ($taskkill -and (Test-Path -LiteralPath $taskkill -PathType Leaf)) {
      # Older SSRVPN builds can start the installer as a child process. Avoid
      # /T here so the installer's own cleanup script does not kill itself.
      & $taskkill /F /PID $app.ProcessId 2>$null | Out-Null
    } else {
      Stop-Process -Id $app.ProcessId -Force -ErrorAction Stop
    }
  } catch {
    Write-Warning "Could not stop SSRVPN app PID $($app.ProcessId)."
  }
}
foreach ($launcher in $installedLaunchers) {
  try {
    if ($taskkill -and (Test-Path -LiteralPath $taskkill -PathType Leaf)) {
      & $taskkill /F /PID $launcher.ProcessId 2>$null | Out-Null
    } else {
      Stop-Process -Id $launcher.ProcessId -Force -ErrorAction Stop
    }
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
    Stop-Process -Id $core.ProcessId -Force -ErrorAction Stop
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
  Write-Warning 'SSRVPN files are still in use; refusing a partial overwrite.'
  exit 2
} elseif ($InstalledCorePidPath) {
  Remove-Item -LiteralPath $InstalledCorePidPath -Force `
    -ErrorAction SilentlyContinue
}

exit 0
