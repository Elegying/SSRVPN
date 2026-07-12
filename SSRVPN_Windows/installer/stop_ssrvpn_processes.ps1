param(
  [string]$InstalledCorePath = '',
  [string]$InstalledCorePidPath = ''
)

$ErrorActionPreference = 'Stop'
$currentSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId

function Get-ProcessesByName {
  param([Parameter(Mandatory = $true)][string]$Name)

  return @(
    Get-CimInstance -ClassName Win32_Process -Filter "Name = '$Name'" |
      Where-Object { $_.SessionId -eq $currentSessionId }
  )
}

function Get-RecordedCore {
  param(
    [Parameter(Mandatory = $true)][string]$PidFile,
    [Parameter(Mandatory = $true)][string]$ExpectedPath
  )

  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return $null }
  $recordedPid = 0
  if (-not [int]::TryParse(
      (Get-Content -LiteralPath $PidFile -Raw).Trim(),
      [ref]$recordedPid
    ) -or $recordedPid -le 1) {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    return $null
  }
  $process = Get-CimInstance -ClassName Win32_Process `
    -Filter "ProcessId = $recordedPid" -ErrorAction SilentlyContinue
  $expected = [System.IO.Path]::GetFullPath($ExpectedPath)
  if (-not $process -or
      $process.SessionId -ne $currentSessionId -or
      -not $process.ExecutablePath -or
      -not $expected.Equals(
        [System.IO.Path]::GetFullPath($process.ExecutablePath),
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    return $null
  }
  return [pscustomobject]@{
    ProcessId = [int]$process.ProcessId
    ExecutablePath = $expected
    PidFile = $PidFile
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
  # fails, PowerShell throws and the installer refuses to kill the old app.
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

$apps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
$launchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
$appCorePaths = @(
  $apps |
    Where-Object { $_.ExecutablePath } |
    ForEach-Object {
      [System.IO.Path]::GetFullPath((Join-Path `
        (Split-Path -LiteralPath $_.ExecutablePath -Parent) 'mihomo.exe'))
    }
)
$recordedCores = @()
foreach ($app in $apps) {
  if (-not $app.ExecutablePath) { continue }
  $appDirectory = Split-Path -LiteralPath $app.ExecutablePath -Parent
  $record = Get-RecordedCore `
    -PidFile (Join-Path $appDirectory 'ssrvpn\mihomo.pid') `
    -ExpectedPath (Join-Path $appDirectory 'mihomo.exe')
  if ($record) { $recordedCores += $record }
}
if ($InstalledCorePath -and $InstalledCorePidPath) {
  $record = Get-RecordedCore -PidFile $InstalledCorePidPath `
    -ExpectedPath $InstalledCorePath
  if ($record) { $recordedCores += $record }
}
$recordedCores = @($recordedCores | Sort-Object -Property ProcessId -Unique)
$blockingCorePaths = @($appCorePaths)
if ($InstalledCorePath) {
  $blockingCorePaths += [System.IO.Path]::GetFullPath($InstalledCorePath)
}
$blockingCorePaths = @($blockingCorePaths | Sort-Object -Unique)

$taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
Restore-OwnedSystemProxy
foreach ($app in $apps) {
  & $taskkill /F /T /PID $app.ProcessId 2>$null | Out-Null
}
foreach ($launcher in $launchers) {
  & $taskkill /F /PID $launcher.ProcessId 2>$null | Out-Null
}

Start-Sleep -Milliseconds 400

# taskkill /T handles normal children. Only a PID record written by this
# SSRVPN process authorizes the detached-core fallback.
foreach ($core in $recordedCores) {
  $current = Get-CimInstance -ClassName Win32_Process `
    -Filter "ProcessId = $($core.ProcessId)" -ErrorAction SilentlyContinue
  if ($current -and $current.ExecutablePath -and
      $core.ExecutablePath.Equals(
        [System.IO.Path]::GetFullPath($current.ExecutablePath),
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
    Stop-Process -Id $core.ProcessId -Force -ErrorAction Stop
  }
}

Start-Sleep -Milliseconds 300

$remainingApps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
$remainingLaunchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
$remainingCores = @(
  Get-ProcessesByName -Name 'mihomo.exe' |
    Where-Object {
      $_.ExecutablePath -and
      $blockingCorePaths -contains [System.IO.Path]::GetFullPath($_.ExecutablePath)
    }
)
if ($remainingApps.Count -gt 0 -or
    $remainingLaunchers.Count -gt 0 -or
    $remainingCores.Count -gt 0) {
  Write-Error 'SSRVPN processes are still running.'
  exit 1
}
foreach ($core in $recordedCores) {
  Remove-Item -LiteralPath $core.PidFile -Force -ErrorAction SilentlyContinue
}
