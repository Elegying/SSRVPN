part of 'system_proxy_service.dart';

extension _SystemProxySnapshotReader on SystemProxyService {
  Future<_ProxySnapshot?> _readCurrentProxy({
    Future<void>? cancellation,
  }) async {
    final script = windowsProxyFlagsInterop +
        r'''
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$key = Get-Item -Path $regPath
$item = Get-ItemProperty -Path $regPath
$dword = [Microsoft.Win32.RegistryValueKind]::DWord
if ($null -ne $item.PSObject.Properties['ProxyEnable'] -and
    $key.GetValueKind('ProxyEnable') -ne $dword) {
  throw 'ProxyEnable must be a REG_DWORD value.'
}
if ($null -ne $item.PSObject.Properties['AutoDetect'] -and
    $key.GetValueKind('AutoDetect') -ne $dword) {
  throw 'AutoDetect must be a REG_DWORD value.'
}
[pscustomobject]@{
  connectionFlags = [SsrvpnConnectionFlags]::Read()
  hasProxyEnable = $null -ne $item.PSObject.Properties['ProxyEnable']
  proxyEnable = if ($null -eq $item.ProxyEnable) { 0 } else { [int]$item.ProxyEnable }
  hasProxyServer = $null -ne $item.PSObject.Properties['ProxyServer']
  proxyServer = [string]$item.ProxyServer
  hasProxyOverride = $null -ne $item.PSObject.Properties['ProxyOverride']
  proxyOverride = [string]$item.ProxyOverride
  hasAutoConfigUrl = $null -ne $item.PSObject.Properties['AutoConfigURL']
  autoConfigUrl = [string]$item.AutoConfigURL
  hasAutoDetect = $null -ne $item.PSObject.Properties['AutoDetect']
  autoDetect = if ($null -eq $item.AutoDetect) { 0 } else { [int]$item.AutoDetect }
} | ConvertTo-Json -Compress
''';
    final result = await _runPowerShell(script, cancellation: cancellation);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
    if (result.exitCode != 0) {
      _lastError = formatWindowsPowerShellError('读取 Windows 系统代理失败', result);
      return null;
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      _lastError = 'Windows 系统代理返回了空状态，未修改代理';
      return null;
    }
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Windows proxy state is not an object');
      }
      return _ProxySnapshot.fromJson(decoded);
    } catch (error) {
      _lastError = 'Windows 系统代理返回了无法验证的状态，未修改代理';
      return null;
    }
  }
}
