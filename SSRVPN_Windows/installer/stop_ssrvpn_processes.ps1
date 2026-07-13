param(
  [string]$InstalledCorePath = '',
  [string]$InstalledCorePidPath = ''
)

$ErrorActionPreference = 'Stop'
$currentSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId

function Get-ProcessesByName {
  param([Parameter(Mandatory = $true)][string]$Name)

  try {
    return @(
      Get-CimInstance -ClassName Win32_Process -Filter "Name = '$Name'" `
        -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $currentSessionId }
    )
  } catch {
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    return @(
      Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSessionId } |
        ForEach-Object {
          $executablePath = $null
          try { $executablePath = $_.Path } catch { $executablePath = $null }
          [pscustomobject]@{
            ProcessId = [int]$_.Id
            ExecutablePath = $executablePath
            SessionId = [int]$_.SessionId
          }
        }
    )
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
  Remove-Item -Path $nativePath -Recurse -Force -ErrorAction SilentlyContinue
  if ($env:LOCALAPPDATA) {
    $jsonPath = Join-Path $env:LOCALAPPDATA `
      'SSRVPN\runtime\system_proxy_backup.json'
    Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ProxyRecoveryState {
  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  if (Test-Path -Path $nativePath) {
    $native = Get-ItemProperty -Path $nativePath
    if ([int]$native.Valid -eq 1) {
      return [pscustomobject]@{
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
    }
  }

  if (-not $env:LOCALAPPDATA) { return $null }
  $jsonPath = Join-Path $env:LOCALAPPDATA `
    'SSRVPN\runtime\system_proxy_backup.json'
  if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
    return $null
  }
  $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
  if (-not $json._ownedProxyServer) { return $null }
  return [pscustomobject]@{
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
    ownedProxyOverride = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;' +
      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;' +
      '172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;' +
      '192.168.*'
    restoreInProgress = $false
    activationInProgress = [bool]$json._activationInProgress
    endpointRestoreInProgress = $false
  }
}

function Write-NativeRestoreJournal {
  param(
    [Parameter(Mandatory = $true)]$Backup,
    [switch]$EndpointOnly
  )

  $path = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  New-Item -Path $path -Force | Out-Null
  $values = @{
    Valid = 1
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
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  }
}

function Restore-OwnedSystemProxy {
  $backup = Get-ProxyRecoveryState
  if (-not $backup) { return }

  $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $current = Get-ItemProperty -Path $regPath
  $hasProxyServer = $null -ne $current.PSObject.Properties['ProxyServer']
  $hasProxyOverride = $null -ne $current.PSObject.Properties['ProxyOverride']
  $hasAutoDetect = $null -ne $current.PSObject.Properties['AutoDetect']
  $hasAutoConfigUrl = $null -ne $current.PSObject.Properties['AutoConfigURL']
  $owned = [int]$current.ProxyEnable -eq 1 -and
    $hasProxyServer -and [string]$current.ProxyServer -eq $backup.ownedProxyServer -and
    $hasProxyOverride -and [string]$current.ProxyOverride -eq $backup.ownedProxyOverride -and
    $hasAutoDetect -and [int]$current.AutoDetect -eq 0 -and
    -not $hasAutoConfigUrl
  $endpointOwned = [int]$current.ProxyEnable -eq 1 -and
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
  if ([int]$current.ProxyEnable -eq 1 -and
      $hasProxyServer -and
      [string]$current.ProxyServer -eq [string]$backup.ownedProxyServer) {
    # Keep the recovery journal so the next SSRVPN launch can still restore the
    # exact original settings. Disabling only the dead endpoint prevents an
    # interrupted upgrade from leaving the user offline.
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 0
    Notify-WinInetProxyChange
  }
}

$apps = @()
$launchers = @()
try {
  $apps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
  $launchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
} catch {
  Write-Warning "Could not enumerate all SSRVPN processes: $($_.Exception.Message)"
}

try {
  Restore-OwnedSystemProxy
} catch {
  Write-Warning "Exact system-proxy restore failed: $($_.Exception.Message)"
  try {
    Disable-OwnedSystemProxyEndpoint
  } catch {
    Write-Warning "Could not disable the owned proxy endpoint: $($_.Exception.Message)"
  }
}

$taskkill = if ($env:SystemRoot) {
  Join-Path $env:SystemRoot 'System32\taskkill.exe'
} else {
  $null
}
foreach ($app in $apps) {
  try {
    if ($taskkill -and (Test-Path -LiteralPath $taskkill -PathType Leaf)) {
      & $taskkill /F /T /PID $app.ProcessId 2>$null | Out-Null
    } else {
      Stop-Process -Id $app.ProcessId -Force -ErrorAction Stop
    }
  } catch {
    Write-Warning "Could not stop SSRVPN app PID $($app.ProcessId)."
  }
}
foreach ($launcher in $launchers) {
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

$remainingApps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
$remainingLaunchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
$remainingCores = @(
  Get-ProcessesByName -Name 'mihomo.exe' |
    Where-Object {
      Test-ExactPath -Actual $_.ExecutablePath -Expected $InstalledCorePath
    }
)
if ($remainingApps.Count -gt 0 -or
    $remainingLaunchers.Count -gt 0 -or
    $remainingCores.Count -gt 0) {
  Write-Warning 'Some SSRVPN files may remain locked; Inno restart replacement will be used.'
} elseif ($InstalledCorePidPath) {
  Remove-Item -LiteralPath $InstalledCorePidPath -Force `
    -ErrorAction SilentlyContinue
}

# Cleanup is deliberately best-effort. Inno Setup owns the final copy operation
# and can schedule a locked binary for restart replacement; this helper must not
# turn a recoverable process race into an installation failure.
exit 0
