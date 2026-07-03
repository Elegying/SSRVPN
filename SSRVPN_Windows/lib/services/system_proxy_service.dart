import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';

/// Manages the Windows system proxy while preserving the user's prior values.
class SystemProxyService {
  static final SystemProxyService _instance = SystemProxyService._();
  factory SystemProxyService() => _instance;
  SystemProxyService._();

  bool _proxyEnabled = false;
  bool _ownsProxy = false;
  bool _recoveryPending = false;
  String? _statePath;
  _ProxySnapshot? _previousProxy;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  String? get lastError => _lastError;

  /// Restores proxy settings left behind by an abnormal previous shutdown.
  Future<void> initialize(String dataDir) async {
    if (!Platform.isWindows) return;
    _lastError = null;
    // This snapshot is machine-specific state. Keeping it outside the portable
    // directory prevents a copied folder from restoring another PC's proxy.
    final localAppData = Platform.environment['LOCALAPPDATA'];
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
      // Staleness check: ignore backups older than 24 hours (likely from a
      // different session or a forgotten backup from a long-ago crash).
      final savedAt = data['_savedAt'] as int?;
      if (savedAt != null) {
        final age = DateTime.now().millisecondsSinceEpoch - savedAt;
        if (age > 24 * 60 * 60 * 1000) {
          await backupFile.delete();
          _recoveryPending = false;
          return;
        }
      }
      final snapshot = _ProxySnapshot.fromJson(data);
      if (await _restoreSnapshot(snapshot)) {
        await backupFile.delete();
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

  Future<bool> setSystemProxy(String host, int port) async {
    if (!Platform.isWindows) return false;
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
      if (!_ownsProxy) {
        final snapshot = await _readCurrentProxy();
        if (snapshot == null) {
          _lastError ??= '无法读取当前 Windows 系统代理设置';
          return false;
        }
        await _writeBackup(snapshot);
        _previousProxy = snapshot;
      }

      final proxyServer = '$host:$port';
      final script = '''
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value 1
Set-ItemProperty -Path \$regPath -Name ProxyServer -Type String -Value '$proxyServer'
Set-ItemProperty -Path \$regPath -Name ProxyOverride -Type String -Value '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
Set-ItemProperty -Path \$regPath -Name AutoDetect -Type DWord -Value 0
Remove-ItemProperty -Path \$regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
${_notifyWinInetScript()}
''';

      final result = await _runPowerShell(script);
      if (result.exitCode != 0) {
        _lastError = _formatPowerShellError('写入 Windows 系统代理失败', result);
        await _restoreSnapshot(_previousProxy!);
        await _deleteBackup();
        _previousProxy = null;
        return false;
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
    if (!Platform.isWindows) return false;
    if (!_ownsProxy) {
      _proxyEnabled = false;
      return true;
    }

    final snapshot = _previousProxy;
    if (snapshot == null) return false;

    try {
      if (!await _restoreSnapshot(snapshot)) {
        _lastError ??= '恢复原 Windows 系统代理设置失败';
        return false;
      }
      _ownsProxy = false;
      _proxyEnabled = false;
      _recoveryPending = false;
      _previousProxy = null;

      await _deleteBackup();
      return true;
    } catch (e) {
      _lastError = '恢复 Windows 系统代理异常: $e';
      return false;
    }
  }

  bool _isValidHost(String host) => RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host);

  Future<_ProxySnapshot?> _readCurrentProxy() async {
    const script = r'''
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$item = Get-ItemProperty -Path $regPath
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
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
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
${_notifyWinInetScript()}
''';
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) {
      _lastError = _formatPowerShellError('恢复 Windows 系统代理失败', result);
    }
    return result.exitCode == 0;
  }

  Future<void> _writeBackup(_ProxySnapshot snapshot) async {
    final statePath = _statePath;
    if (statePath == null) {
      throw StateError('SystemProxyService has not been initialized');
    }
    final file = File(statePath);
    await file.parent.create(recursive: true);
    final json = snapshot.toJson();
    json['_savedAt'] = DateTime.now().millisecondsSinceEpoch;
    json['_pid'] = pid;
    final temp = File('$statePath.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(statePath);
  }

  Future<void> _deleteBackup() async {
    final statePath = _statePath;
    if (statePath == null) return;
    final backupFile = File(statePath);
    if (await backupFile.exists()) await backupFile.delete();
  }

  Future<ProcessResult> _runPowerShell(String script) => TimedProcessRunner.run(
        _powerShellExecutable(),
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        timeout: const Duration(seconds: 20),
        timeoutStderr: '电脑性能不足，请重新连接',
      );

  String _powerShellExecutable() {
    if (!Platform.isWindows) return 'powershell';
    final windowsDir =
        Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
    if (windowsDir != null && windowsDir.trim().isNotEmpty) {
      final executable = File(
        '$windowsDir${Platform.pathSeparator}System32'
        '${Platform.pathSeparator}WindowsPowerShell'
        '${Platform.pathSeparator}v1.0'
        '${Platform.pathSeparator}powershell.exe',
      );
      if (executable.existsSync()) return executable.path;
    }
    return 'powershell';
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
