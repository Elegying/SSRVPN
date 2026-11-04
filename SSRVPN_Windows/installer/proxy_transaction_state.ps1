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

function Get-SystemProxyState {
  param([Parameter(Mandatory = $true)]$Value)

  $hasProxyEnable = $null -ne $Value.PSObject.Properties['ProxyEnable']
  $hasProxyServer = $null -ne $Value.PSObject.Properties['ProxyServer']
  $hasProxyOverride = $null -ne $Value.PSObject.Properties['ProxyOverride']
  $hasAutoConfigUrl = $null -ne $Value.PSObject.Properties['AutoConfigURL']
  $hasAutoDetect = $null -ne $Value.PSObject.Properties['AutoDetect']
  return [pscustomobject]@{
    hasProxyEnable = $hasProxyEnable
    proxyEnable = if ($hasProxyEnable) { [int]$Value.ProxyEnable } else { 0 }
    hasProxyServer = $hasProxyServer
    proxyServer = if ($hasProxyServer) { [string]$Value.ProxyServer } else { '' }
    hasProxyOverride = $hasProxyOverride
    proxyOverride = if ($hasProxyOverride) { [string]$Value.ProxyOverride } else { '' }
    hasAutoConfigUrl = $hasAutoConfigUrl
    autoConfigUrl = if ($hasAutoConfigUrl) { [string]$Value.AutoConfigURL } else { '' }
    hasAutoDetect = $hasAutoDetect
    autoDetect = if ($hasAutoDetect) { [int]$Value.AutoDetect } else { 0 }
  }
}

function Copy-ProxyState {
  param([Parameter(Mandatory = $true)]$Value)
  return [pscustomobject]@{
    hasProxyEnable = [bool]$Value.hasProxyEnable
    proxyEnable = [int]$Value.proxyEnable
    hasProxyServer = [bool]$Value.hasProxyServer
    proxyServer = [string]$Value.proxyServer
    hasProxyOverride = [bool]$Value.hasProxyOverride
    proxyOverride = [string]$Value.proxyOverride
    hasAutoConfigUrl = [bool]$Value.hasAutoConfigUrl
    autoConfigUrl = [string]$Value.autoConfigUrl
    hasAutoDetect = [bool]$Value.hasAutoDetect
    autoDetect = [int]$Value.autoDetect
  }
}

function Test-ProxyStatesEqual {
  param(
    [Parameter(Mandatory = $true)]$Left,
    [Parameter(Mandatory = $true)]$Right
  )
  return [bool]$Left.hasProxyEnable -eq [bool]$Right.hasProxyEnable -and
    [int]$Left.proxyEnable -eq [int]$Right.proxyEnable -and
    [bool]$Left.hasProxyServer -eq [bool]$Right.hasProxyServer -and
    [string]$Left.proxyServer -ceq [string]$Right.proxyServer -and
    [bool]$Left.hasProxyOverride -eq [bool]$Right.hasProxyOverride -and
    [string]$Left.proxyOverride -ceq [string]$Right.proxyOverride -and
    [bool]$Left.hasAutoConfigUrl -eq [bool]$Right.hasAutoConfigUrl -and
    [string]$Left.autoConfigUrl -ceq [string]$Right.autoConfigUrl -and
    [bool]$Left.hasAutoDetect -eq [bool]$Right.hasAutoDetect -and
    [int]$Left.autoDetect -eq [int]$Right.autoDetect
}

function Get-ProxyActivationPrefixes {
  param(
    [Parameter(Mandatory = $true)]$Original,
    [Parameter(Mandatory = $true)]$Owned
  )
  $state = Copy-ProxyState -Value $Original
  $states = @((Copy-ProxyState -Value $state))
  $state.hasProxyServer = [bool]$Owned.hasProxyServer
  $state.proxyServer = [string]$Owned.proxyServer
  $states += Copy-ProxyState -Value $state
  $state.hasProxyOverride = [bool]$Owned.hasProxyOverride
  $state.proxyOverride = [string]$Owned.proxyOverride
  $states += Copy-ProxyState -Value $state
  $state.hasAutoDetect = [bool]$Owned.hasAutoDetect
  $state.autoDetect = [int]$Owned.autoDetect
  $states += Copy-ProxyState -Value $state
  $state.hasAutoConfigUrl = [bool]$Owned.hasAutoConfigUrl
  $state.autoConfigUrl = [string]$Owned.autoConfigUrl
  $states += Copy-ProxyState -Value $state
  $state.hasProxyEnable = [bool]$Owned.hasProxyEnable
  $state.proxyEnable = [int]$Owned.proxyEnable
  $states += Copy-ProxyState -Value $state
  return $states
}

function Test-ReachableProxyTransactionState {
  param(
    [Parameter(Mandatory = $true)]$Current,
    [Parameter(Mandatory = $true)]$Original,
    [Parameter(Mandatory = $true)]$Owned,
    [ValidateSet('Activation', 'FullRestore', 'EndpointRestore')]
    [Parameter(Mandatory = $true)][string]$Phase
  )
  $activation = @(Get-ProxyActivationPrefixes -Original $Original -Owned $Owned)
  if ($Phase -eq 'Activation') {
    foreach ($state in $activation) {
      if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    }
    return $false
  }
  if ($Phase -eq 'EndpointRestore') {
    $ownedServer = [bool]$Current.hasProxyServer -eq [bool]$Owned.hasProxyServer -and
      [string]$Current.proxyServer -ceq [string]$Owned.proxyServer
    $originalServer =
      [bool]$Current.hasProxyServer -eq [bool]$Original.hasProxyServer -and
      [string]$Current.proxyServer -ceq [string]$Original.proxyServer
    $ownedProxy = [bool]$Current.hasProxyEnable -eq [bool]$Owned.hasProxyEnable -and
      [int]$Current.proxyEnable -eq [int]$Owned.proxyEnable
    $disabledProxy = [bool]$Current.hasProxyEnable -and
      [int]$Current.proxyEnable -eq 0
    $originalProxy = [bool]$Current.hasProxyEnable -eq [bool]$Original.hasProxyEnable -and
      [int]$Current.proxyEnable -eq [int]$Original.proxyEnable
    $originalMayBeDisabled = -not [bool]$Original.hasProxyEnable -or
      [int]$Original.proxyEnable -eq 0
    return ($ownedServer -and ($ownedProxy -or $disabledProxy)) -or
      ($originalServer -and ($originalProxy -or
        ($originalMayBeDisabled -and $disabledProxy)))
  }

  foreach ($candidate in $activation) {
    $state = Copy-ProxyState -Value $candidate
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    if (-not [bool]$Original.hasProxyEnable -or
        [int]$Original.proxyEnable -eq 0) {
      $state.hasProxyEnable = $true
      $state.proxyEnable = 0
      if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    }
    $state.hasProxyServer = [bool]$Original.hasProxyServer
    $state.proxyServer = [string]$Original.proxyServer
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasProxyOverride = [bool]$Original.hasProxyOverride
    $state.proxyOverride = [string]$Original.proxyOverride
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasAutoConfigUrl = [bool]$Original.hasAutoConfigUrl
    $state.autoConfigUrl = [string]$Original.autoConfigUrl
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasAutoDetect = [bool]$Original.hasAutoDetect
    $state.autoDetect = [int]$Original.autoDetect
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasProxyEnable = [bool]$Original.hasProxyEnable
    $state.proxyEnable = [int]$Original.proxyEnable
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
  }
  return $false
}

# Turns the Windows "Automatically detect settings" switch back on after a
# proxy session ended without a replayable recovery record. The LAN checkbox
# is stored twice: byte 8 of DefaultConnectionSettings (under the Connections
# subkey, where the dialog keeps the per-connection flags) and the legacy
# AutoDetect DWORD that WinINet reads back when it rebuilds those flags. Both
# are written ahead of the caller's WinINet notification, because restoring
# either one alone leaves the checkbox off.
# This only ever turns the switch on: nothing except an explicit user action
# may clear it, and the caller must already have proven the endpoint was ours.
function Restore-AbandonedAutoDetect {
  param([Parameter(Mandatory = $true)][string]$Path)

  $current = Get-ItemProperty -Path $Path
  $autoDetect = $current.PSObject.Properties['AutoDetect']
  $connectionsPath = Join-Path $Path 'Connections'
  $blob = $null
  if (Test-Path -LiteralPath $connectionsPath) {
    $stored = Get-ItemProperty -LiteralPath $connectionsPath
    $flags = $stored.PSObject.Properties['DefaultConnectionSettings']
    if ($null -ne $flags -and $flags.Value -is [byte[]] -and
        $flags.Value.Length -ge 9) {
      $blob = $flags.Value
    }
  }
  $flagsOn = $null -ne $blob -and ([int]$blob[8] -band 8) -ne 0
  $dwordOn = $null -ne $autoDetect -and $autoDetect.Value -is [int] -and
    [int]$autoDetect.Value -eq 1
  if ($flagsOn -and $dwordOn) { return $false }

  $updated = $null
  if ($null -ne $blob) {
    $updated = [byte[]]$blob.Clone()
    $updated[8] = [byte]($updated[8] -bor 8)
  }
  Set-ItemProperty -Path $Path -Name AutoDetect -Type DWord -Value 1
  if ($null -ne $updated) {
    Set-ItemProperty -LiteralPath $connectionsPath `
      -Name DefaultConnectionSettings -Type Binary -Value $updated
  }
  return $true
}

# Reports whether this installation holds any proxy recovery record. This is
# a pure path probe with no dependency on process identity, so it lives with
# the other proxy transaction state helpers rather than in the process
# stopper that consumes it. The ownership rule built on top of it is
# documented in docs/decisions/020-installer-system-proxy-ownership.md.
function Test-ProxyRecoveryStatePresent {
  $nativePath = 'HKCU:\Software\SSRVPN\RuntimeProxyBackup'
  if (Test-Path -Path $nativePath) { return $true }
  if (-not $env:LOCALAPPDATA) { return $false }
  $jsonPath = Join-Path $env:LOCALAPPDATA `
    'SSRVPN\runtime\system_proxy_backup.json'
  return Test-Path -LiteralPath $jsonPath -PathType Leaf
}

# Installation explicitly resets the current user's proxy, regardless of origin.
# Called only while both the transaction lock and app-instance gate are held.
function Clear-InstallerSystemProxy {
  $script:InstallerResetStep = 'Proxy process/service cleanup'
  Stop-InstallerProxyTools
  $script:InstallerResetStep = 'WinHTTP / proxy environment reset'
  Clear-InstallerMachineProxy
  $script:InstallerResetStep = 'Current-user Internet Settings reset'
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  Clear-InstallerProxyRegistry -Path $path
  $script:InstallerResetStep = 'WinINet connection flags reset'
  Set-InstallerWinInetDirect
  $script:InstallerResetStep = 'SSRVPN recovery record cleanup'
  Remove-ProxyRecoveryState
  Notify-WinInetProxyChange
  $script:InstallerResetStep = 'Proxy reset verification'
  Test-InstallerWinInetDirect
  $current = Get-ItemProperty -Path $path -ErrorAction Stop
  $remaining = @()
  foreach ($name in @('ProxyEnable', 'AutoDetect')) {
    $property = $current.PSObject.Properties[$name]
    if ($null -ne $property -and $property.Value -ne 0) { $remaining += $name }
  }
  foreach ($name in @('ProxyServer', 'AutoConfigURL')) {
    $property = $current.PSObject.Properties[$name]
    if ($null -ne $property -and
        -not [string]::IsNullOrEmpty([string]$property.Value)) { $remaining += $name }
  }
  if ($remaining.Count -gt 0) {
    throw ('Proxy settings were rewritten or not cleared: ' + ($remaining -join ', '))
  }
}

function Set-InstallerWinInetDirect {
  if (-not ('SsrVpnInstallerDirect' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SsrVpnInstallerDirect {
  [StructLayout(LayoutKind.Explicit, Size=8)]
  struct Value {
    [FieldOffset(0)] public int Flags;
    [FieldOffset(0)] public IntPtr Pointer;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct Option { public int Id; public Value Value; }
  [StructLayout(LayoutKind.Sequential)]
  struct Options {
    public int Size; public IntPtr Connection; public int Count;
    public int Error; public IntPtr Values;
  }
  [DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool InternetSetOptionW(IntPtr handle, int option,
    ref Options values, int length);
  [DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool InternetQueryOptionW(IntPtr handle, int option,
    ref Options values, ref int length);
  public static void Reset() {
    int size = Marshal.SizeOf(typeof(Option));
    var values = new Options { Size = Marshal.SizeOf(typeof(Options)), Count = 4 };
    values.Values = Marshal.AllocHGlobal(size * 4);
    IntPtr empty = Marshal.StringToHGlobalUni("");
    try {
      for (int i = 0; i < 4; i++) {
        var option = new Option { Id = i + 1 };
        if (i == 0) option.Value.Flags = 1;
        else option.Value.Pointer = empty;
        Marshal.StructureToPtr(option, IntPtr.Add(values.Values, size * i), false);
      }
      if (!InternetSetOptionW(IntPtr.Zero, 75, ref values, values.Size))
        throw new Win32Exception(Marshal.GetLastWin32Error());
    } finally {
      Marshal.FreeHGlobal(empty);
      Marshal.FreeHGlobal(values.Values);
    }
  }
  public static void Verify() {
    var values = new Options { Size = Marshal.SizeOf(typeof(Options)), Count = 1 };
    values.Values = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Option)));
    try {
      Marshal.StructureToPtr(new Option { Id = 1 }, values.Values, false);
      int length = values.Size;
      if (!InternetQueryOptionW(IntPtr.Zero, 75, ref values, ref length))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      var actual = (Option)Marshal.PtrToStructure(values.Values, typeof(Option));
      if ((actual.Value.Flags & 15) != 1)
        throw new InvalidOperationException("WinINet proxy flags remain enabled: " + actual.Value.Flags);
    } finally { Marshal.FreeHGlobal(values.Values); }
  }
}
"@
  }
  [SsrVpnInstallerDirect]::Reset()
}

function Clear-InstallerMachineProxy {
  # Installation is elevated; do not silently accept an unelevated partial reset.
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator permission is required to reset machine proxy settings.'
  }
  Clear-InstallerProxyRegistry -Path `
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
  & $netsh winhttp reset proxy | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "WinHTTP reset failed: exit=$LASTEXITCODE" }
  foreach ($scope in @('Machine', 'User', 'Process')) {
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'FTP_PROXY', 'NO_PROXY')) {
      [Environment]::SetEnvironmentVariable($name, $null, $scope)
      if ([Environment]::GetEnvironmentVariable($name, $scope)) {
        throw "Proxy environment variable remained: scope=$scope name=$name"
      }
    }
  }
}

function Stop-InstallerProxyTools {
  # Exact known executable names only; never kill by a fuzzy window/title match.
  $names = @('clash', 'clash-win64', 'clash-meta', 'clash-verge',
    'Clash for Windows', 'v2rayN', 'v2ray', 'xray', 'sing-box',
    'Shadowsocks', 'ShadowsocksR', 'ss-local', 'ssr-local', 'hysteria')
  foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
    $executable = ''
    if ([string]$service.PathName -match '^\s*"([^"]+\.exe)"') {
      $executable = $matches[1]
    } elseif ([string]$service.PathName -match '^\s*(\S+\.exe)(?:\s|$)') {
      $executable = $matches[1]
    }
    if ($executable -and
        @($names + 'mihomo') -contains [IO.Path]::GetFileNameWithoutExtension($executable) -and
        $service.State -ne 'Stopped') {
      try {
        $controller = Get-Service -Name $service.Name -ErrorAction Stop
        $controller.Stop()
        $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(8))
      } catch { throw "Proxy service could not stop: $($service.Name); file=$executable" }
    }
  }
  foreach ($process in @(Get-Process -ErrorAction Stop)) {
    if ($names -notcontains $process.ProcessName) { continue }
    $label = "$($process.ProcessName) PID=$($process.Id)"
    try {
      # Acquire the handle before terminating, so PID reuse cannot select a new process.
      $handle = $process.Handle
      $actualImage = Get-InstallerProxyProcessImage -Handle $handle
      if ($names -notcontains [IO.Path]::GetFileNameWithoutExtension($actualImage)) {
        throw 'Process identity changed before termination'
      }
      if (-not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw 'Timed out' }
      }
    } catch {
      $exited = $false
      try { $exited = $process.HasExited } catch {}
      if (-not $exited) { throw "Proxy process could not stop: $label" }
    }
    finally { $process.Dispose() }
  }
  $remaining = @(Get-Process -ErrorAction Stop |
    Where-Object { $names -contains $_.ProcessName })
  if ($remaining.Count -gt 0) {
    throw ('Proxy process restarted: ' + (($remaining | ForEach-Object {
      "$($_.ProcessName) PID=$($_.Id)"
    }) -join ', '))
  }
}

function Invoke-InstallerProxyReset {
  $script:InstallerResetStep = 'System proxy reset'
  try { Clear-InstallerSystemProxy } catch {
    Set-StopStatus -Status 'PROXY_UNSAFE'
    $detail = $script:InstallerResetStep + ': ' + $_.Exception.Message
    if ($StatusPath) {
      try {
        [IO.File]::WriteAllText($StatusPath + '.detail', $detail,
          [Text.UTF8Encoding]::new($false))
      } catch {}
    }
    Write-Warning $detail
    exit 3
  }
}

function Clear-InstallerProxyRegistry {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
    New-Item -Path $path -ErrorAction Stop | Out-Null
  }
  Set-ItemProperty -Path $path -Name ProxyEnable -Type DWord -Value 0 -ErrorAction Stop
  Set-ItemProperty -Path $path -Name AutoDetect -Type DWord -Value 0 -ErrorAction Stop
  foreach ($name in @('ProxyServer', 'ProxyOverride', 'AutoConfigURL')) {
    $current = Get-ItemProperty -Path $path -ErrorAction Stop
    if ($null -ne $current.PSObject.Properties[$name]) {
      Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop
    }
  }
}

function Test-InstallerWinInetDirect {
  [SsrVpnInstallerDirect]::Verify()
}

function Get-InstallerProxyProcessImage {
  param([Parameter(Mandatory = $true)][IntPtr]$Handle)
  if (-not ('SsrVpnInstallerProcessImage' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class SsrVpnInstallerProcessImage {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool QueryFullProcessImageName(IntPtr process, int flags,
    StringBuilder path, ref int size);
  public static string Read(IntPtr process) {
    int size = 32768;
    var path = new StringBuilder(size);
    if (!QueryFullProcessImageName(process, 0, path, ref size))
      throw new Win32Exception(Marshal.GetLastWin32Error());
    return path.ToString();
  }
}
"@
  }
  return [SsrVpnInstallerProcessImage]::Read($Handle)
}
