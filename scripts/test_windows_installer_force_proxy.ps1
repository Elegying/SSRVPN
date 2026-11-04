$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\SSRVPN_Windows\installer\proxy_transaction_state.ps1')
# Exercise the real reset orchestration against an isolated registry model.
# Never change the build machine's network settings.
$script:State = @{}
$script:Failure = ''
$script:Cleaned = $false
$script:Notified = $false
$script:ToolsStopped = $false
function Clear-InstallerMachineProxy {
  if (-not $script:ToolsStopped) { throw 'Proxy tools must stop before reset' }
  if ($script:Failure -eq 'machine') { throw 'injected machine reset failure' }
}
function Stop-InstallerProxyTools {
  $script:ToolsStopped = $true
  if ($script:Failure -eq 'process') { throw 'injected process failure' }
}
function Test-Path { param($LiteralPath, $ErrorAction) return $true }
function New-Item { param($Path, [switch]$Force, $ErrorAction) }
function Set-ItemProperty {
  param($Path, $Name, $Type, $Value, $ErrorAction)
  if ($script:Failure -eq 'write') { throw 'injected write failure' }
  $script:State[$Name] = $Value
}
function Get-ItemProperty {
  param($Path, $ErrorAction)
  if ($script:Failure -eq 'read') { throw 'injected read failure' }
  return [pscustomobject]$script:State
}
function Remove-ItemProperty {
  param($Path, $Name, $ErrorAction)
  if ($script:Failure -ne 'persist') { $script:State.Remove($Name) }
}
function Remove-ProxyRecoveryState {
  if ($script:Failure -eq 'journal') { throw 'injected journal failure' }
  $script:Cleaned = $true
}
function Test-InstallerWinInetDirect {
  if ($script:Failure -eq 'native-query') { throw 'injected native readback failure' }
}
function Set-InstallerWinInetDirect {
  if ($script:Failure -eq 'native-missing') {
    $script:State.Remove('ProxyEnable'); $script:State.Remove('AutoDetect')
  }
  if ($script:Failure -eq 'native-empty') {
    $script:State['ProxyServer'] = ''; $script:State['AutoConfigURL'] = ''
  }
  if ($script:Failure -eq 'wininet') { throw 'injected WinINet failure' }
}
function Notify-WinInetProxyChange { $script:Notified = $true }
foreach ($enabled in @(0, 1, 7, 'broken')) {
  foreach ($server in @('127.0.0.1:7890', 'proxy.example:8080', '')) {
    $script:State = @{ ProxyEnable = $enabled; ProxyServer = $server;
      AutoDetect = 1; AutoConfigURL = 'https://example.invalid/proxy.pac';
      ProxyOverride = '<local>' }
    $script:Cleaned = $false
    $script:Notified = $false
$script:ToolsStopped = $false
    Clear-InstallerSystemProxy
    if ($script:State.ProxyEnable -ne 0 -or $script:State.AutoDetect -ne 0 -or
        $script:State.ContainsKey('ProxyServer') -or
        $script:State.ContainsKey('AutoConfigURL') -or
        $script:State.ContainsKey('ProxyOverride') -or
        -not $script:Cleaned -or -not $script:Notified) { throw 'Reset failed' }
  }
}
$script:Failure = 'native-empty'
$script:State = @{}
Clear-InstallerSystemProxy
$script:Failure = 'native-missing'
$script:State = @{}
Clear-InstallerSystemProxy
foreach ($failure in @('write', 'read', 'journal', 'persist', 'wininet', 'machine', 'process', 'native-query')) {
  $script:Failure = $failure
  $script:State = @{ ProxyServer = 'proxy.example:8080'; AutoConfigURL = 'pac' }
  $threw = $false
  try { Clear-InstallerSystemProxy } catch { $threw = $true }
  if (-not $threw) { throw "Failure was swallowed: $failure" }
}
Write-Host 'Installer force-proxy reset: 14 configurations and 8 failures passed.'

# Reload the production process cleanup, then replace only OS entry points.
. (Join-Path $PSScriptRoot '..\SSRVPN_Windows\installer\proxy_transaction_state.ps1')
$script:Killed = $false
$script:ServiceStopped = $false
$script:Denied = $false
$script:Restarted = $false
$script:Replaced = $false
$script:ExitedBeforeOpen = $false
function Get-CimInstance {
  param($ClassName, $ErrorAction)
  return [pscustomobject]@{ Name = 'proxy-test';
    PathName = '"C:\test\sing-box.exe" run'; State = 'Running' }
}
function Get-Service {
  param($Name, $ErrorAction)
  $fake = [pscustomobject]@{}
  $fake | Add-Member ScriptMethod Stop { $script:ServiceStopped = $true }
  $fake | Add-Member ScriptMethod WaitForStatus { param($Status, $Timeout) }
  return $fake
}
function Get-InstallerProxyProcessImage {
  param($Handle)
  if ($script:Replaced) { return 'C:\test\browser.exe' }
  return 'C:\test\sing-box.exe'
}
function Get-Process {
  param($ErrorAction)
  $foreign = [pscustomobject]@{ ProcessName = 'browser'; Id = 50 }
  if ($script:Killed -and -not $script:Restarted) { return $foreign }
  $fake = [pscustomobject]@{ ProcessName = 'sing-box'; Id = 51;
    Handle = 1; HasExited = $false }
  if ($script:ExitedBeforeOpen) {
    $fake.HasExited = $true
    $fake.PSObject.Properties.Remove('Handle')
    $fake | Add-Member ScriptProperty Handle { throw 'Already exited' }
    $script:Killed = $true
  }
  $fake | Add-Member ScriptMethod Kill {
    if ($script:Denied) { throw 'Access denied' }
    $script:Killed = $true
  }
  $fake | Add-Member ScriptMethod WaitForExit { param($Timeout) return $true }
  $fake | Add-Member ScriptMethod Dispose {}
  return @($foreign, $fake)
}
Stop-InstallerProxyTools
if (-not $script:Killed -or -not $script:ServiceStopped) { throw 'Known tools survived' }
$script:Killed = $false
$script:Denied = $true
try { Stop-InstallerProxyTools; throw 'Expected PID failure' } catch {
  if ($_.Exception.Message -notmatch 'sing-box PID=51') { throw }
}
$script:Denied = $false
$script:Restarted = $true
try { Stop-InstallerProxyTools; throw 'Expected restart failure' } catch {
  if ($_.Exception.Message -notmatch 'restarted.*sing-box PID=51') { throw }
}
$script:Restarted = $false
$script:Killed = $false
$script:Replaced = $true
try { Stop-InstallerProxyTools; throw 'Expected identity failure' } catch {
  if ($_.Exception.Message -notmatch 'sing-box PID=51') { throw }
}
if ($script:Killed) { throw 'Reused PID was killed' }
$script:Replaced = $false
$script:ExitedBeforeOpen = $true
Stop-InstallerProxyTools
Write-Host 'Proxy tool cleanup: known service/process, unrelated process, denial and restart passed.'

# Compile the exact native declaration without changing this host's proxy.
$source = Get-Content (Join-Path $PSScriptRoot '..\SSRVPN_Windows\installer\proxy_transaction_state.ps1') -Encoding UTF8 -Raw
$native = [regex]::Match($source, '(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@')
if (-not $native.Success) { throw 'Native declaration missing' }
Add-Type -TypeDefinition $native.Groups[1].Value
$optionType = [SsrVpnInstallerDirect].GetNestedType('Option', 'NonPublic')
$expectedSize = if ([IntPtr]::Size -eq 8) { 16 } else { 12 }
if ([Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($optionType)) -ne $expectedSize) {
  throw 'WinINet option union has incorrect architecture alignment'
}
Write-Host 'WinINet interop declaration compiled and native option layout verified.'

. (Join-Path $PSScriptRoot '..\SSRVPN_Windows\installer\proxy_transaction_state.ps1')
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
  $image = Get-InstallerProxyProcessImage -Handle $self.Handle
  if ([IO.Path]::GetFileName($image) -ine [IO.Path]::GetFileName($self.MainModule.FileName)) {
    throw 'Held process handle did not identify its executable'
  }
} finally { $self.Dispose() }
Write-Host 'Held-handle image lookup, PID replacement and already-exited process verified.'
