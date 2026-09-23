$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load only predicates: never run the stop script or touch the host's WinINet.
$root = Split-Path -Path $PSScriptRoot -Parent
$stopperPath = Join-Path $root 'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $stopperPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Could not parse the packaged stopper.' }
foreach ($functionName in @(
    'Test-RequiredProperties', 'Test-OwnedProxyServer', 'Test-DwordFlag',
    'Test-NativeRecoveryJournalNonReplayable', 'Test-SystemProxySafeToStop'
  )) {
  $definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq $functionName
  }, $false)
  if ($null -eq $definition) { throw "Missing predicate: $functionName" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $root 'SSRVPN_Windows\installer\proxy_transaction_state.ps1')

$script:OwnedProxyOverride = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;' +
  '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;' +
  '172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
$script:NativeRecord = $null
$script:JsonPresent = $false
$script:ReadFailure = $false
$script:CurrentProxy = $null
$script:CasesPassed = 0

function Test-Path {
  param([string]$Path, [string]$LiteralPath, [string]$PathType)
  if ($script:ReadFailure) { throw 'Injected recovery-state read failure.' }
  if ($Path -eq 'HKCU:\Software\SSRVPN\RuntimeProxyBackup') {
    return $null -ne $script:NativeRecord
  }
  if ($LiteralPath -and $LiteralPath.EndsWith('\SSRVPN\runtime\system_proxy_backup.json')) {
    if ($PathType -ne 'Leaf') { throw 'JSON recovery probe must require a file.' }
    return $script:JsonPresent
  }
  throw "Unexpected path probe: $Path $LiteralPath"
}

function Get-ItemProperty {
  param([string]$Path)
  if ($script:ReadFailure) { throw 'Injected registry read failure.' }
  if ($Path -eq 'HKCU:\Software\SSRVPN\RuntimeProxyBackup') {
    return $script:NativeRecord
  }
  if ($Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') {
    return $script:CurrentProxy
  }
  throw "Unexpected registry read: $Path"
}

function Set-ItemProperty { throw 'Proxy verification must never write registry values.' }
function Remove-ItemProperty { throw 'Proxy verification must never remove registry values.' }
function Remove-Item { throw 'Proxy verification must never delete recovery records.' }

function Assert-ProxySafety {
  param([string]$Name, [bool]$Expected, [AllowNull()]$Backup = $null)
  $arguments = @{ Backup = $Backup }
  # Model a live foreign mihomo candidate if the old parameter reappears.
  if ((Get-Command Test-SystemProxySafeToStop).Parameters.ContainsKey('InstalledProcessRunning')) {
    $arguments.InstalledProcessRunning = $true
  }
  $actual = Test-SystemProxySafeToStop @arguments
  if ($actual -ne $Expected) {
    throw "$Name returned safe=$actual; expected $Expected."
  }
  $script:CasesPassed++
}

foreach ($port in @(1, 7890, 65535)) {
  foreach ($bypass in @('<local>', $script:OwnedProxyOverride)) {
    $script:CurrentProxy = [pscustomobject]@{
      ProxyEnable = 1; ProxyServer = "127.0.0.1:$port"
      ProxyOverride = $bypass; AutoDetect = 0
    }
    Assert-ProxySafety -Name "Foreign mihomo / port $port / bypass $bypass" -Expected $true
  }
}
$script:CurrentProxy.ProxyServer = '127.0.0.1:7890'
$ownedBackup = [pscustomobject]@{ ownedProxyServer = '127.0.0.1:7890' }
Assert-ProxySafety -Name 'Captured owned endpoint still enabled' -Expected $false -Backup $ownedBackup
$script:CurrentProxy.ProxyOverride = '<local>'
$script:CurrentProxy.AutoDetect = 1
Assert-ProxySafety -Name 'Owned endpoint with edited ancillary values' -Expected $false -Backup $ownedBackup
$script:CurrentProxy.ProxyServer = '127.0.0.1:7891'
Assert-ProxySafety -Name 'External endpoint replaces owned endpoint' -Expected $true -Backup $ownedBackup

$script:CurrentProxy.ProxyOverride = $script:OwnedProxyOverride
$script:CurrentProxy.AutoDetect = 0
$script:JsonPresent = $true
Assert-ProxySafety -Name 'Invalid JSON record corroborates owned fingerprint' -Expected $false
$script:JsonPresent = $false
foreach ($record in @(
    [pscustomobject]@{ Valid = 0 },
    [pscustomobject]@{
      Valid = 1; RestoreInProgress = 0; ActivationInProgress = 0
      EndpointRestoreInProgress = 0
    }
  )) {
  $script:NativeRecord = $record
  Assert-ProxySafety -Name 'Native record corroborates owned fingerprint' -Expected $false
}

# Pending or malformed journals must remain blocked after an endpoint change.
$script:CurrentProxy.ProxyServer = 'proxy.example:8080'
foreach ($pendingName in @('RestoreInProgress', 'ActivationInProgress', 'EndpointRestoreInProgress')) {
  $script:NativeRecord = [pscustomobject]@{
    Valid = 1; RestoreInProgress = 0; ActivationInProgress = 0
    EndpointRestoreInProgress = 0
  }
  $script:NativeRecord.$pendingName = 1
  Assert-ProxySafety -Name "Pending $pendingName with external endpoint" -Expected $false
}
foreach ($record in @(
    [pscustomobject]@{}, [pscustomobject]@{ Valid = '1' },
    [pscustomobject]@{ Valid = 1 }, [pscustomobject]@{ Valid = 2 }
  )) {
  $script:NativeRecord = $record
  Assert-ProxySafety -Name 'Malformed native journal' -Expected $false
}
$script:NativeRecord = [pscustomobject]@{ Valid = 0 }
Assert-ProxySafety -Name 'Terminal journal with external endpoint' -Expected $true
$script:NativeRecord = $null
$script:JsonPresent = $true
Assert-ProxySafety -Name 'JSON record with external endpoint' -Expected $true
$script:JsonPresent = $false
foreach ($flag in @('1', 2, -1, $null)) {
  $script:CurrentProxy.ProxyEnable = $flag
  Assert-ProxySafety -Name 'Invalid ProxyEnable fails closed' -Expected $false
}
$script:CurrentProxy = [pscustomobject]@{ ProxyEnable = 1 }
Assert-ProxySafety -Name 'Enabled proxy without endpoint' -Expected $false
$script:NativeRecord = [pscustomobject]@{ Valid = 1 }
$script:CurrentProxy = [pscustomobject]@{ ProxyEnable = 0 }
Assert-ProxySafety -Name 'Disabled endpoint with pending journal' -Expected $true
$script:CurrentProxy = [pscustomobject]@{}
Assert-ProxySafety -Name 'Absent ProxyEnable' -Expected $true
$script:ReadFailure = $true
Assert-ProxySafety -Name 'Unreadable proxy state' -Expected $false
Write-Host "Windows proxy ownership tests passed: $($script:CasesPassed) cases."
