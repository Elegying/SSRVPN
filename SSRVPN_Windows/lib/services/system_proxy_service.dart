import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/src/services/system_proxy_ownership.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

typedef SystemProxyScriptRunner = Future<ProcessResult> Function(String script);

/// Manages the Windows system proxy while preserving the user's prior values.
class SystemProxyService {
  static const _nativeBackupRegistryPath =
      r'HKCU:\Software\SSRVPN\RuntimeProxyBackup';
  static const _ownedProxyOverride =
      '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
      '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
      '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
  static final SystemProxyService _instance = SystemProxyService._();
  factory SystemProxyService() => _instance;
  SystemProxyService._({
    bool? isWindows,
    SystemProxyScriptRunner? scriptRunner,
    String? localAppData,
  })  : _isWindows = isWindows ?? Platform.isWindows,
        _scriptRunner = scriptRunner,
        _localAppDataOverride = localAppData;

  factory SystemProxyService.forTesting({
    required bool isWindows,
    required SystemProxyScriptRunner scriptRunner,
    String localAppData = '',
  }) =>
      SystemProxyService._(
        isWindows: isWindows,
        scriptRunner: scriptRunner,
        localAppData: localAppData,
      );

  final bool _isWindows;
  final SystemProxyScriptRunner? _scriptRunner;
  final String? _localAppDataOverride;

  bool _proxyEnabled = false;
  bool _ownsProxy = false;
  bool _recoveryPending = false;
  String? _dataDir;
  Future<bool>? _recoveryOperation;
  String? _statePath;
  _ProxySnapshot? _previousProxy;
  String? _ownedProxyServer;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  bool get recoveryPending => _recoveryPending;
  String? get lastError => _lastError;

  /// Restores proxy settings left behind by an abnormal previous shutdown.
  Future<void> initialize(String dataDir) async {
    if (!_isWindows) return;
    _dataDir = dataDir;
    _lastError = null;
    // This snapshot is machine-specific state. Keeping it outside the portable
    // directory prevents a copied folder from restoring another PC's proxy.
    final localAppData =
        _localAppDataOverride ?? Platform.environment['LOCALAPPDATA'];
    final runtimeDir = localAppData == null || localAppData.trim().isEmpty
        ? dataDir
        : '$localAppData${Platform.pathSeparator}SSRVPN'
            '${Platform.pathSeparator}runtime';
    await Directory(runtimeDir).create(recursive: true);
    _statePath = '$runtimeDir${Platform.pathSeparator}system_proxy_backup.json';
    final backupFile = File(_statePath!);
    if (!await backupFile.exists()) return;

    try {
      final data =
          jsonDecode(await backupFile.readAsString()) as Map<String, dynamic>;
      final snapshot = _ProxySnapshot.fromJson(data);
      final rawOwnedProxyServer = data['_ownedProxyServer'];
      final ownedProxyServer =
          rawOwnedProxyServer is String ? rawOwnedProxyServer : null;
      final activationInProgress = data['_activationInProgress'] == true;
      final current = await _readCurrentProxy();
      if (current == null) {
        _recoveryPending = true;
        _lastError ??= '无法读取当前 Windows 系统代理设置，稍后重试恢复';
        return;
      }
      final ownsFullFingerprint = _isOwnedProxy(current, ownedProxyServer);
      final ownsEndpoint = _isOwnedEndpoint(current, ownedProxyServer);
      if (!ownsFullFingerprint && !ownsEndpoint && !activationInProgress) {
        // The user or another app changed the proxy, or this is a legacy
        // backup without ownership metadata. Never overwrite that state.
        await _deleteBackup();
        _forgetOwnership();
        _recoveryPending = false;
        return;
      }

      _previousProxy = snapshot;
      _ownedProxyServer = ownedProxyServer;
      _ownsProxy = true;
      _proxyEnabled = true;
      final restored = ownsFullFingerprint || activationInProgress
          ? await _restoreSnapshot(snapshot)
          : await _restoreOwnedEndpoint(snapshot);
      if (restored) {
        await _deleteBackup();
        _forgetOwnership();
        _recoveryPending = false;
      } else {
        _recoveryPending = true;
        _lastError = '上次异常退出后的系统代理设置未能恢复';
      }
    } catch (e) {
      // Keep the backup for a future retry instead of deleting recovery data.
      _recoveryPending = true;
      _lastError = '读取系统代理恢复文件失败: $e';
    }
  }

  /// Retries startup recovery after a transient registry/PowerShell failure.
  /// The backup is never discarded merely to make a new connection possible.
  Future<bool> retryPendingRecovery() {
    if (!_recoveryPending) return Future<bool>.value(true);
    final current = _recoveryOperation;
    if (current != null) return current;

    final operation = _retryPendingRecoveryInternal();
    _recoveryOperation = operation;
    operation.then<void>(
      (_) => _clearRecoveryOperation(operation),
      onError: (_, __) => _clearRecoveryOperation(operation),
    );
    return operation;
  }

  void _clearRecoveryOperation(Future<bool> operation) {
    if (identical(_recoveryOperation, operation)) {
      _recoveryOperation = null;
    }
  }

  Future<bool> _retryPendingRecoveryInternal() async {
    final dataDir = _dataDir;
    final statePath = _statePath;
    if (dataDir == null || statePath == null) {
      _lastError = '系统代理恢复服务尚未初始化';
      return false;
    }
    if (!await File(statePath).exists()) {
      _lastError = '系统代理恢复文件缺失，无法安全恢复旧设置';
      return false;
    }

    await initialize(dataDir);
    return !_recoveryPending;
  }

  Future<bool> setSystemProxy(String host, int port) async {
    if (!_isWindows) return false;
    _lastError = null;
    if (_recoveryPending) {
      _lastError = '系统代理仍有未恢复的旧状态，请查看运行日志';
      return false;
    }
    if (!_isValidHost(host) || port < 1 || port > 65535) {
      _lastError = '代理地址或端口无效: $host:$port';
      return false;
    }

    try {
      final proxyServer = '$host:$port';
      if (_ownsProxy && _ownedProxyServer != proxyServer) {
        // Release the old endpoint before acquiring a different one so the
        // recovery record always names the proxy that is actually installed.
        if (!await clearSystemProxy()) return false;
        _lastError = null;
      }
      if (!_ownsProxy) {
        final snapshot = await _readCurrentProxy();
        if (snapshot == null) {
          _lastError ??= '无法读取当前 Windows 系统代理设置';
          return false;
        }
        await _writeBackup(snapshot, proxyServer);
        _previousProxy = snapshot;
        _ownedProxyServer = proxyServer;
      }

      final script = '''
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
Set-ItemProperty -Path \$regPath -Name ProxyServer -Type String -Value '$proxyServer'
Set-ItemProperty -Path \$regPath -Name ProxyOverride -Type String -Value '$_ownedProxyOverride'
Set-ItemProperty -Path \$regPath -Name AutoDetect -Type DWord -Value 0
Remove-ItemProperty -Path \$regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value 1
${_notifyWinInetScript()}
''';

      final result = await _runPowerShell(script);
      if (result.exitCode != 0) {
        final setError = _formatPowerShellError('写入 Windows 系统代理失败', result);
        return _rollbackFailedAcquisition(setError);
      }
      try {
        await _markActivationComplete();
      } catch (e) {
        return _rollbackFailedAcquisition('提交 Windows 系统代理状态失败: $e');
      }

      _ownsProxy = true;
      _proxyEnabled = true;
      return true;
    } catch (e) {
      _lastError = '设置 Windows 系统代理异常: $e';
      return false;
    }
  }

  /// Restores the values captured before SSRVPN enabled its proxy.
  Future<bool> clearSystemProxy() async {
    if (!_isWindows) return false;
    final recovery = _recoveryOperation;
    if (recovery != null) {
      try {
        await recovery;
      } catch (e) {
        _recoveryPending = true;
        _lastError = '等待系统代理恢复任务失败: $e';
        return false;
      }
    }
    _lastError = null;
    if (!_ownsProxy) {
      if (_recoveryPending) {
        _lastError = '系统代理仍有未恢复的旧状态，请重试';
        return false;
      }
      _proxyEnabled = false;
      return true;
    }

    final snapshot = _previousProxy;
    if (snapshot == null) {
      _recoveryPending = true;
      _lastError = '系统代理恢复快照缺失，无法安全恢复旧设置';
      return false;
    }

    try {
      final current = await _readCurrentProxy();
      if (current == null) {
        _recoveryPending = true;
        _lastError ??= '无法读取当前 Windows 系统代理设置，稍后重试恢复';
        return false;
      }
      if (!_isOwnedProxy(current, _ownedProxyServer)) {
        // If the endpoint is still ours, release only that endpoint while
        // preserving PAC, bypass and auto-detect changes made after connect.
        if (_isOwnedEndpoint(current, _ownedProxyServer) &&
            !await _restoreOwnedEndpoint(snapshot)) {
          _recoveryPending = true;
          _lastError ??= '释放 SSRVPN 系统代理端点失败';
          return false;
        }
        await _deleteBackup();
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }

      if (!await _restoreSnapshot(snapshot)) {
        _recoveryPending = true;
        _lastError ??= '恢复原 Windows 系统代理设置失败';
        return false;
      }
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      return true;
    } catch (e) {
      _recoveryPending = true;
      _lastError = '恢复 Windows 系统代理异常: $e';
      return false;
    }
  }

  bool _isValidHost(String host) => RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host);

  Future<bool> _rollbackFailedAcquisition(String setError) async {
    _recoveryPending = true;
    final snapshot = _previousProxy;
    final restored = snapshot != null && await _restoreSnapshot(snapshot);
    if (!restored) {
      final restoreError = _lastError;
      _lastError = restoreError == null ? setError : '$setError；$restoreError';
      return false;
    }
    await _deleteBackup();
    _forgetOwnership();
    _recoveryPending = false;
    _lastError = setError;
    return false;
  }

  bool _isOwnedProxy(_ProxySnapshot current, String? ownedProxyServer) =>
      isOwnedWindowsProxy(
        proxyEnable: current.proxyEnable,
        hasProxyServer: current.hasProxyServer,
        proxyServer: current.proxyServer,
        ownedProxyServer: ownedProxyServer,
        hasProxyOverride: current.hasProxyOverride,
        proxyOverride: current.proxyOverride,
        ownedProxyOverride: _ownedProxyOverride,
        hasAutoConfigUrl: current.hasAutoConfigUrl,
        autoConfigUrl: current.autoConfigUrl,
        hasAutoDetect: current.hasAutoDetect,
        autoDetect: current.autoDetect,
      );

  bool _isOwnedEndpoint(_ProxySnapshot current, String? ownedProxyServer) =>
      isOwnedWindowsProxyEndpoint(
        proxyEnable: current.proxyEnable,
        hasProxyServer: current.hasProxyServer,
        proxyServer: current.proxyServer,
        ownedProxyServer: ownedProxyServer,
      );

  void _forgetOwnership() {
    _ownsProxy = false;
    _proxyEnabled = false;
    _previousProxy = null;
    _ownedProxyServer = null;
  }

  Future<_ProxySnapshot?> _readCurrentProxy() async {
    const script = r'''
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
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) {
      _lastError = _formatPowerShellError('读取 Windows 系统代理失败', result);
      return null;
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) return null;
    return _ProxySnapshot.fromJson(
      jsonDecode(output) as Map<String, dynamic>,
    );
  }

  Future<bool> _restoreSnapshot(_ProxySnapshot snapshot) async {
    final server = base64Encode(utf8.encode(snapshot.proxyServer));
    final override = base64Encode(utf8.encode(snapshot.proxyOverride));
    final script = '''
\$backupPath = '$_nativeBackupRegistryPath'
Set-ItemProperty -Path \$backupPath -Name RestoreInProgress -Type DWord -Value 1
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
if (${snapshot.hasProxyServer ? r'$true' : r'$false'}) {
  \$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$server'))
  Set-ItemProperty -Path \$regPath -Name ProxyServer -Type String -Value \$value
} else {
  Remove-ItemProperty -Path \$regPath -Name ProxyServer -ErrorAction SilentlyContinue
}
if (${snapshot.hasProxyOverride ? r'$true' : r'$false'}) {
  \$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$override'))
  Set-ItemProperty -Path \$regPath -Name ProxyOverride -Type String -Value \$value
} else {
  Remove-ItemProperty -Path \$regPath -Name ProxyOverride -ErrorAction SilentlyContinue
}
if (${snapshot.hasAutoConfigUrl ? r'$true' : r'$false'}) {
  \$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Encode(utf8.encode(snapshot.autoConfigUrl))}'))
  Set-ItemProperty -Path \$regPath -Name AutoConfigURL -Type String -Value \$value
} else {
  Remove-ItemProperty -Path \$regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
}
if (${snapshot.hasAutoDetect ? r'$true' : r'$false'}) {
  Set-ItemProperty -Path \$regPath -Name AutoDetect -Type DWord -Value ${snapshot.autoDetect}
} else {
  Remove-ItemProperty -Path \$regPath -Name AutoDetect -ErrorAction SilentlyContinue
}
Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
${_notifyWinInetScript()}
''';
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) {
      _lastError = _formatPowerShellError('恢复 Windows 系统代理失败', result);
    }
    return result.exitCode == 0;
  }

  Future<bool> _restoreOwnedEndpoint(_ProxySnapshot snapshot) async {
    final server = base64Encode(utf8.encode(snapshot.proxyServer));
    final script = '''
\$backupPath = '$_nativeBackupRegistryPath'
Set-ItemProperty -Path \$backupPath -Name EndpointRestoreInProgress -Type DWord -Value 1
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
if (${snapshot.hasProxyServer ? r'$true' : r'$false'}) {
  \$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$server'))
  Set-ItemProperty -Path \$regPath -Name ProxyServer -Type String -Value \$value
} else {
  Remove-ItemProperty -Path \$regPath -Name ProxyServer -ErrorAction SilentlyContinue
}
Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
${_notifyWinInetScript()}
''';
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) {
      _lastError = _formatPowerShellError('释放 Windows 系统代理端点失败', result);
    }
    return result.exitCode == 0;
  }

  Future<void> _writeBackup(
    _ProxySnapshot snapshot,
    String ownedProxyServer,
  ) async {
    final statePath = _statePath;
    if (statePath == null) {
      throw StateError('SystemProxyService has not been initialized');
    }
    final file = File(statePath);
    await file.parent.create(recursive: true);
    final json = snapshot.toJson();
    json['_ownedProxyServer'] = ownedProxyServer;
    json['_savedAt'] = DateTime.now().millisecondsSinceEpoch;
    json['_pid'] = pid;
    json['_activationInProgress'] = true;
    final temp = File('$statePath.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(statePath);
    try {
      await _writeNativeRecoveryBackup(snapshot, ownedProxyServer);
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> _deleteBackup() async {
    final result = await _runPowerShell('''
\$backupPath = '$_nativeBackupRegistryPath'
if (Test-Path -LiteralPath \$backupPath) {
  Remove-Item -LiteralPath \$backupPath -Recurse -Force
}
''');
    if (result.exitCode != 0) {
      throw StateError(
        _formatPowerShellError('删除 Windows 原生代理恢复状态失败', result),
      );
    }
    final statePath = _statePath;
    if (statePath == null) return;
    final backupFile = File(statePath);
    if (await backupFile.exists()) await backupFile.delete();
  }

  Future<void> _writeNativeRecoveryBackup(
    _ProxySnapshot snapshot,
    String ownedProxyServer,
  ) async {
    String encoded(String value) => base64Encode(utf8.encode(value));
    final script = '''
\$backupPath = '$_nativeBackupRegistryPath'
if (Test-Path -LiteralPath \$backupPath) {
  Remove-Item -LiteralPath \$backupPath -Recurse -Force
}
New-Item -Path \$backupPath -Force | Out-Null
Set-ItemProperty -Path \$backupPath -Name OriginalProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
Set-ItemProperty -Path \$backupPath -Name HasProxyServer -Type DWord -Value ${snapshot.hasProxyServer ? 1 : 0}
\$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded(snapshot.proxyServer)}'))
Set-ItemProperty -Path \$backupPath -Name OriginalProxyServer -Type String -Value \$value
Set-ItemProperty -Path \$backupPath -Name HasProxyOverride -Type DWord -Value ${snapshot.hasProxyOverride ? 1 : 0}
\$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded(snapshot.proxyOverride)}'))
Set-ItemProperty -Path \$backupPath -Name OriginalProxyOverride -Type String -Value \$value
Set-ItemProperty -Path \$backupPath -Name HasAutoConfigURL -Type DWord -Value ${snapshot.hasAutoConfigUrl ? 1 : 0}
\$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded(snapshot.autoConfigUrl)}'))
Set-ItemProperty -Path \$backupPath -Name OriginalAutoConfigURL -Type String -Value \$value
Set-ItemProperty -Path \$backupPath -Name HasAutoDetect -Type DWord -Value ${snapshot.hasAutoDetect ? 1 : 0}
Set-ItemProperty -Path \$backupPath -Name OriginalAutoDetect -Type DWord -Value ${snapshot.autoDetect}
Set-ItemProperty -Path \$backupPath -Name OwnedProxyServer -Type String -Value '$ownedProxyServer'
Set-ItemProperty -Path \$backupPath -Name OwnedProxyOverride -Type String -Value '$_ownedProxyOverride'
Set-ItemProperty -Path \$backupPath -Name RestoreInProgress -Type DWord -Value 0
Set-ItemProperty -Path \$backupPath -Name EndpointRestoreInProgress -Type DWord -Value 0
Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 1
Set-ItemProperty -Path \$backupPath -Name Valid -Type DWord -Value 1
''';
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) {
      throw StateError(
        _formatPowerShellError('写入 Windows 原生代理恢复状态失败', result),
      );
    }
  }

  Future<void> _markActivationComplete() async {
    final result = await _runPowerShell('''
\$backupPath = '$_nativeBackupRegistryPath'
Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 0
''');
    if (result.exitCode != 0) {
      throw StateError(
        _formatPowerShellError('更新 Windows 原生代理恢复状态失败', result),
      );
    }

    final statePath = _statePath;
    if (statePath == null) {
      throw StateError('System proxy state path is missing');
    }
    final file = File(statePath);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    json['_activationInProgress'] = false;
    final temp = File('$statePath.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(statePath);
  }

  Future<ProcessResult> _runPowerShell(String script) {
    final utf8Script = windowsPowerShellUtf8Script(script);
    final override = _scriptRunner;
    if (override != null) return override(utf8Script);
    return TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        utf8Script,
      ],
      timeout: const Duration(seconds: 20),
      timeoutStderr: '电脑性能不足，请重新连接',
    );
  }

  String _formatPowerShellError(String prefix, ProcessResult result) {
    if (result.exitCode == 124) return '电脑性能不足，请重新连接';
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    return detail.isEmpty
        ? '$prefix（退出码 ${result.exitCode}）'
        : '$prefix（退出码 ${result.exitCode}）: $detail';
  }

  String _notifyWinInetScript() => r'''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SsrVpnWinInet {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);
}
"@
[SsrVpnWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[SsrVpnWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''';
}

class _ProxySnapshot {
  const _ProxySnapshot({
    required this.proxyEnable,
    required this.hasProxyServer,
    required this.proxyServer,
    required this.hasProxyOverride,
    required this.proxyOverride,
    required this.hasAutoConfigUrl,
    required this.autoConfigUrl,
    required this.hasAutoDetect,
    required this.autoDetect,
  });

  final int proxyEnable;
  final bool hasProxyServer;
  final String proxyServer;
  final bool hasProxyOverride;
  final String proxyOverride;
  final bool hasAutoConfigUrl;
  final String autoConfigUrl;
  final bool hasAutoDetect;
  final int autoDetect;

  factory _ProxySnapshot.fromJson(Map<String, dynamic> json) {
    return _ProxySnapshot(
      proxyEnable: (json['proxyEnable'] as num?)?.toInt() ?? 0,
      hasProxyServer: json['hasProxyServer'] as bool? ?? false,
      proxyServer: json['proxyServer'] as String? ?? '',
      hasProxyOverride: json['hasProxyOverride'] as bool? ?? false,
      proxyOverride: json['proxyOverride'] as String? ?? '',
      hasAutoConfigUrl: json['hasAutoConfigUrl'] as bool? ?? false,
      autoConfigUrl: json['autoConfigUrl'] as String? ?? '',
      hasAutoDetect: json['hasAutoDetect'] as bool? ?? false,
      autoDetect: (json['autoDetect'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'proxyEnable': proxyEnable,
        'hasProxyServer': hasProxyServer,
        'proxyServer': proxyServer,
        'hasProxyOverride': hasProxyOverride,
        'proxyOverride': proxyOverride,
        'hasAutoConfigUrl': hasAutoConfigUrl,
        'autoConfigUrl': autoConfigUrl,
        'hasAutoDetect': hasAutoDetect,
        'autoDetect': autoDetect,
      };
}
