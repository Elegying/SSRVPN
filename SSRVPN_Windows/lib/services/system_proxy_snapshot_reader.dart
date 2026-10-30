part of 'system_proxy_service.dart';

extension _SystemProxySnapshotReader on SystemProxyService {
  Future<_ProxySnapshot?> _readCurrentProxy({
    Future<void>? cancellation,
    bool checkPolicy = false,
    bool checkGuardian = false,
  }) async =>
      (await _readProxyState(
              cancellation: cancellation,
              checkPolicy: checkPolicy,
              checkGuardian: checkGuardian))
          .snapshot;

  Future<({bool? policySupported, _ProxySnapshot? snapshot})> _readProxyState({
    Future<void>? cancellation,
    bool checkPolicy = false,
    bool checkGuardian = false,
  }) async {
    if (checkPolicy && (_scriptRunner == null || _nativeSnapshot != null)) {
      return _readNativeProxyState(
          checkGuardian: checkGuardian, cancellation: cancellation);
    }
    // Policy is read-only: never modify HKLM to permit per-user acquisition.
    final script = (checkPolicy ? windowsPerUserProxyPolicyScript : '') +
        (checkGuardian ? _launcherGuardianScript : '') +
        windowsProxyFlagsInterop +
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
    final result = await _runTimedPowerShell(
        checkGuardian
            ? _ProxyCommandPhase.preflight
            : checkPolicy
                ? _ProxyCommandPhase.verify
                : _ProxyCommandPhase.snapshot,
        script,
        cancellation: cancellation);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
    final policySupported =
        checkPolicy ? windowsPerUserProxyPolicyResult(result) : null;
    if (checkPolicy && policySupported == false) {
      _lastError = 'Windows 代理策略不允许按用户设置代理，请检查 ProxySettingsPerUser';
      return (policySupported: false, snapshot: null);
    }
    if (checkGuardian &&
        result.exitCode == 3 &&
        result.stdout.toString().trim() == 'SSRVPN_PROXY_GUARDIAN_NOT_READY') {
      _lastError = '独立系统代理保护未就绪，请通过 ssrvpn_windows.exe 启动或重试';
      return (policySupported: null, snapshot: null);
    }
    if (result.exitCode != 0) {
      _lastError = formatWindowsPowerShellError('读取 Windows 系统代理失败', result);
      return (policySupported: policySupported, snapshot: null);
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      _lastError = 'Windows 系统代理返回了空状态，未修改代理';
      return (policySupported: policySupported, snapshot: null);
    }
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Windows proxy state is not an object');
      }
      return (
        policySupported: policySupported,
        snapshot: _ProxySnapshot.fromJson(decoded)
      );
    } catch (error) {
      _lastError = 'Windows 系统代理返回了无法验证的状态，未修改代理';
      return (policySupported: policySupported, snapshot: null);
    }
  }
}
