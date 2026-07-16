import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/src/services/system_proxy_ownership.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

typedef SystemProxyScriptRunner = Future<ProcessResult> Function(String script);

/// Manages the Windows system proxy while preserving the user's prior values.
class SystemProxyService {
  static const _nativeBackupRegistryPath =
      r'HKCU:\Software\SSRVPN\RuntimeProxyBackup';
  static const _runOnceRegistryPath =
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';
  static const _runOnceValueName = 'SSRVPNProxyRecovery';
  static const _recoveryOnlyArgument = '--recover-proxy-only';
  static const _launcherGuardianMutexName =
      r'Local\SSRVPN_Windows_LauncherGuardian';
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
    String? recoveryExecutable,
  })  : _isWindows = isWindows ?? Platform.isWindows,
        _scriptRunner = scriptRunner,
        _localAppDataOverride = localAppData,
        _recoveryExecutableOverride = recoveryExecutable;

  factory SystemProxyService.forTesting({
    required bool isWindows,
    required SystemProxyScriptRunner scriptRunner,
    String localAppData = '',
    String? recoveryExecutable,
  }) =>
      SystemProxyService._(
        isWindows: isWindows,
        scriptRunner: scriptRunner,
        localAppData: localAppData,
        recoveryExecutable: recoveryExecutable,
      );

  final bool _isWindows;
  final SystemProxyScriptRunner? _scriptRunner;
  final String? _localAppDataOverride;
  final String? _recoveryExecutableOverride;

  bool _proxyEnabled = false;
  bool _ownsProxy = false;
  bool _recoveryPending = false;
  bool _endpointSafeWithPendingRecovery = false;
  String? _dataDir;
  Future<bool>? _recoveryOperation;
  String? _statePath;
  String? _transactionLockPath;
  _ProxySnapshot? _previousProxy;
  String? _ownedProxyServer;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  bool get recoveryPending => _recoveryPending;
  bool get endpointSafeWithPendingRecovery =>
      _recoveryPending && _endpointSafeWithPendingRecovery;
  String? get lastError => _lastError;

  /// Restores proxy settings left behind by an abnormal previous shutdown.
  Future<void> initialize(String dataDir) async {
    if (!_isWindows) return;
    _dataDir = dataDir;
    _lastError = null;
    _endpointSafeWithPendingRecovery = false;
    // This snapshot is machine-specific state. Keeping it outside the install
    // directory prevents copied app files from restoring another PC's proxy.
    final localAppData =
        _localAppDataOverride ?? Platform.environment['LOCALAPPDATA'];
    if (localAppData == null ||
        localAppData.trim().isEmpty ||
        !p.isAbsolute(localAppData)) {
      _recoveryPending = true;
      _lastError = 'LOCALAPPDATA 不可用，无法建立独立系统代理恢复保护';
      return;
    }
    final runtimeDir = '$localAppData${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}runtime';
    await Directory(runtimeDir).create(recursive: true);
    _statePath = '$runtimeDir${Platform.pathSeparator}system_proxy_backup.json';
    _transactionLockPath =
        '$runtimeDir${Platform.pathSeparator}system_proxy_transaction.lock';
    final backupFile = File(_statePath!);

    try {
      await _withProxyTransactionLock(() async {
        if (!await backupFile.exists()) {
          _forgetOwnership();
          _recoveryPending = false;
          return;
        }
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
        var trustedActivation = false;
        if (activationInProgress && !ownsFullFingerprint) {
          final nativePending =
              await _hasMatchingPendingNativeRecovery(ownedProxyServer);
          if (nativePending == null && !ownsEndpoint) {
            _recoveryPending = true;
            _lastError = '无法确认 Windows 原生代理恢复状态，稍后重试';
            return;
          }
          trustedActivation = nativePending == true;
        }
        if (!ownsFullFingerprint && !ownsEndpoint && !trustedActivation) {
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
        final restored = ownsFullFingerprint || trustedActivation
            ? await _restoreSnapshot(snapshot)
            : await _restoreOwnedEndpoint(snapshot);
        if (restored) {
          try {
            await _deleteBackup();
            _forgetOwnership();
            _recoveryPending = false;
          } catch (cleanupError) {
            await _finishFailedClearIfEndpointSafe(
              '上次异常退出后的系统代理已恢复，但恢复日志清理失败: '
              '$cleanupError',
            );
          }
        } else {
          await _finishFailedClearIfEndpointSafe(
            '上次异常退出后的系统代理设置未能恢复',
          );
        }
      });
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
    try {
      return await _withProxyTransactionLock(
        () => _setSystemProxyUnlocked(host, port),
      );
    } catch (e) {
      _lastError = '系统代理事务锁失败: $e';
      return false;
    }
  }

  Future<bool> isCurrentSystemProxyOwned() async {
    if (!_isWindows) return false;
    try {
      return await _withProxyTransactionLock(
        _isCurrentSystemProxyOwnedUnlocked,
      );
    } catch (e) {
      _lastError = '系统代理状态检查失败: $e';
      return false;
    }
  }

  Future<bool> _isCurrentSystemProxyOwnedUnlocked() async {
    if (!_ownsProxy) {
      _lastError = 'SSRVPN 当前未持有 Windows 系统代理';
      return false;
    }
    final current = await _readCurrentProxy();
    if (current == null) {
      _lastError ??= '无法读取当前 Windows 系统代理设置';
      return false;
    }
    if (!_isOwnedProxy(current, _ownedProxyServer)) {
      _lastError = 'Windows 系统代理已被关闭或修改';
      return false;
    }
    return true;
  }

  Future<bool> _setSystemProxyUnlocked(String host, int port) async {
    if (!_isWindows) return false;
    _lastError = null;
    var acquisitionPrepared = false;
    if (_recoveryPending) {
      _lastError = '系统代理仍有未恢复的旧状态，请查看运行日志';
      return false;
    }
    if (!_isValidHost(host) || port < 1 || port > 65535) {
      _lastError = '代理地址或端口无效: $host:$port';
      return false;
    }

    try {
      if (!await isLauncherGuardianReady()) {
        _lastError = '独立系统代理保护未就绪，请通过 ssrvpn_windows.exe 启动或重试';
        return false;
      }
      final proxyServer = '$host:$port';
      if (_ownsProxy && _ownedProxyServer != proxyServer) {
        // Release the old endpoint before acquiring a different one so the
        // recovery record always names the proxy that is actually installed.
        if (!await _clearSystemProxyUnlocked()) return false;
        _lastError = null;
      }
      if (!_ownsProxy) {
        final snapshot = await _readCurrentProxy();
        if (snapshot == null) {
          _lastError ??= '无法读取当前 Windows 系统代理设置';
          return false;
        }
        _previousProxy = snapshot;
        _ownedProxyServer = proxyServer;
        // Recovery responsibility begins before the first journal write. If
        // journal preparation only partially succeeds, its cleanup must still
        // fail closed instead of letting another acquisition overwrite it.
        _ownsProxy = true;
        acquisitionPrepared = true;
        await _writeBackup(snapshot, proxyServer);
      }
      acquisitionPrepared = true;

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

      if (!await _isCurrentSystemProxyOwnedUnlocked()) {
        final verificationError = _lastError ?? '无法确认 Windows 系统代理已生效';
        final released = await _clearSystemProxyUnlocked();
        final releaseError = _lastError;
        _lastError = released || releaseError == null
            ? verificationError
            : '$verificationError；$releaseError';
        return false;
      }

      _proxyEnabled = true;
      return true;
    } catch (e) {
      final setError = '设置 Windows 系统代理异常: $e';
      if (acquisitionPrepared) {
        return _rollbackFailedAcquisition(setError);
      }
      _lastError = setError;
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

    try {
      return await _withProxyTransactionLock(_clearSystemProxyUnlocked);
    } catch (e) {
      _recoveryPending = true;
      _lastError = '系统代理事务锁失败: $e';
      return false;
    }
  }

  Future<bool> _clearSystemProxyUnlocked() async {
    if (!_isWindows) return false;
    _lastError = null;
    _endpointSafeWithPendingRecovery = false;
    if (!_ownsProxy) {
      if (_recoveryPending) {
        return _finishFailedClearIfEndpointSafe('系统代理仍有未清理的旧恢复状态');
      }
      _proxyEnabled = false;
      return true;
    }

    final snapshot = _previousProxy;
    if (snapshot == null) {
      return _finishFailedClearIfEndpointSafe('系统代理恢复快照缺失，无法恢复旧设置');
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
          return _finishFailedClearIfEndpointSafe(
            _lastError ?? '释放 SSRVPN 系统代理端点失败',
          );
        }
        await _deleteBackup();
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }

      if (!await _restoreSnapshot(snapshot)) {
        return _finishFailedClearIfEndpointSafe(
          _lastError ?? '恢复原 Windows 系统代理设置失败',
        );
      }
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      return true;
    } catch (e) {
      return _finishFailedClearIfEndpointSafe('恢复 Windows 系统代理异常: $e');
    }
  }

  Future<bool> _finishFailedClearIfEndpointSafe(String error) async {
    _recoveryPending = true;
    _endpointSafeWithPendingRecovery = false;
    final current = await _readCurrentProxy();
    if (current == null) {
      final readError = _lastError;
      _lastError = readError == null ? error : '$error；$readError';
      return false;
    }
    if (!_isCurrentProxyEndpointSafeToStop(current)) {
      _lastError = error;
      return false;
    }

    _proxyEnabled = false;
    try {
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      _lastError = null;
      return true;
    } catch (cleanupError) {
      _endpointSafeWithPendingRecovery = true;
      _lastError = '$error；SSRVPN 代理端点已安全释放，但恢复日志仍待清理: '
          '$cleanupError';
      return false;
    }
  }

  bool _isCurrentProxyEndpointSafeToStop(_ProxySnapshot current) {
    if (current.proxyEnable == 0) return true;
    if (current.proxyEnable != 1 || !current.hasProxyServer) return false;
    final ownedProxyServer = _ownedProxyServer;
    if (ownedProxyServer == null || ownedProxyServer.isEmpty) return false;
    return current.proxyServer != ownedProxyServer;
  }

  Future<T> _withProxyTransactionLock<T>(Future<T> Function() operation) async {
    final lockPath = _transactionLockPath;
    if (lockPath == null) {
      throw StateError('SystemProxyService has not been initialized');
    }
    final lockFile = File(lockPath);
    await lockFile.parent.create(recursive: true);
    final handle = await lockFile.open(mode: FileMode.append);
    var locked = false;
    try {
      await handle.lock(FileLock.exclusive);
      locked = true;
      return await operation();
    } finally {
      try {
        if (locked) await handle.unlock();
      } finally {
        await handle.close();
      }
    }
  }

  bool _isValidHost(String host) => RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host);

  Future<bool> isLauncherGuardianReady() async {
    try {
      final result = await _runPowerShell('''
\$guardian = [System.Threading.Mutex]::OpenExisting('$_launcherGuardianMutexName')
try {
  \$acquired = \$false
  try {
    \$acquired = \$guardian.WaitOne(0)
  } catch [System.Threading.AbandonedMutexException] {
    \$acquired = \$true
  }
  if (\$acquired) {
    \$guardian.ReleaseMutex()
    throw 'Guardian mutex is not owned.'
  }
} finally {
  \$guardian.Dispose()
}
''');
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool?> _hasMatchingPendingNativeRecovery(
    String? ownedProxyServer,
  ) async {
    if (ownedProxyServer == null || ownedProxyServer.isEmpty) return false;
    final encodedServer = base64Encode(utf8.encode(ownedProxyServer));
    final result = await _runPowerShell('''
\$backupPath = '$_nativeBackupRegistryPath'
if (-not (Test-Path -LiteralPath \$backupPath)) {
  [Console]::Out.Write('terminal')
  exit 0
}
\$key = Get-Item -LiteralPath \$backupPath
\$item = Get-ItemProperty -LiteralPath \$backupPath
\$dword = [Microsoft.Win32.RegistryValueKind]::DWord
\$expectedServer = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String('$encodedServer'))
\$valid = \$null -ne \$item.PSObject.Properties['Valid'] -and
  \$key.GetValueKind('Valid') -eq \$dword -and [int]\$item.Valid -eq 1
\$owned = \$null -ne \$item.PSObject.Properties['OwnedProxyServer'] -and
  [string]\$item.OwnedProxyServer -eq \$expectedServer -and
  \$null -ne \$item.PSObject.Properties['OwnedProxyOverride'] -and
  [string]\$item.OwnedProxyOverride -eq '$_ownedProxyOverride'
\$pending = \$false
foreach (\$name in @(
  'ActivationInProgress',
  'RestoreInProgress',
  'EndpointRestoreInProgress'
)) {
  if (\$null -ne \$item.PSObject.Properties[\$name] -and
      \$key.GetValueKind(\$name) -eq \$dword -and
      [int](\$item.PSObject.Properties[\$name].Value) -eq 1) {
    \$pending = \$true
  }
}
if (\$valid -and \$owned -and \$pending) {
  [Console]::Out.Write('pending')
} else {
  [Console]::Out.Write('terminal')
}
''');
    if (result.exitCode != 0) return null;
    final output = result.stdout.toString().trim();
    if (output == 'pending') return true;
    if (output == 'terminal') return false;
    return null;
  }

  Future<bool> _rollbackFailedAcquisition(String setError) async {
    _recoveryPending = true;
    final snapshot = _previousProxy;
    final restored = snapshot != null && await _restoreSnapshot(snapshot);
    if (!restored) {
      final restoreError = _lastError;
      final combinedError =
          restoreError == null ? setError : '$setError；$restoreError';
      await _finishFailedClearIfEndpointSafe(combinedError);
      return false;
    }
    try {
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      _lastError = setError;
    } catch (e) {
      await _finishFailedClearIfEndpointSafe('$setError；恢复状态清理失败: $e');
    }
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
    _endpointSafeWithPendingRecovery = false;
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
\$validTerminal = \$false
try {
  Set-ItemProperty -Path \$backupPath -Name Valid -Type DWord -Value 0 -ErrorAction Stop
  \$validTerminal = \$true
} catch {}
\$flagsTerminal = \$true
try { Set-ItemProperty -Path \$backupPath -Name RestoreInProgress -Type DWord -Value 0 -ErrorAction Stop } catch { \$flagsTerminal = \$false }
try { Set-ItemProperty -Path \$backupPath -Name EndpointRestoreInProgress -Type DWord -Value 0 -ErrorAction Stop } catch { \$flagsTerminal = \$false }
try { Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 0 -ErrorAction Stop } catch { \$flagsTerminal = \$false }
if (-not (\$validTerminal -or \$flagsTerminal)) {
  throw 'Could not terminalize the native proxy recovery journal.'
}
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
\$validTerminal = \$false
try {
  Set-ItemProperty -Path \$backupPath -Name Valid -Type DWord -Value 0 -ErrorAction Stop
  \$validTerminal = \$true
} catch {}
\$flagsTerminal = \$true
try { Set-ItemProperty -Path \$backupPath -Name RestoreInProgress -Type DWord -Value 0 -ErrorAction Stop } catch { \$flagsTerminal = \$false }
try { Set-ItemProperty -Path \$backupPath -Name EndpointRestoreInProgress -Type DWord -Value 0 -ErrorAction Stop } catch { \$flagsTerminal = \$false }
try { Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 0 -ErrorAction Stop } catch { \$flagsTerminal = \$false }
if (-not (\$validTerminal -or \$flagsTerminal)) {
  throw 'Could not terminalize the native proxy recovery journal.'
}
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
      await _registerRunOnceRecovery();
    } catch (acquisitionError) {
      try {
        await _deleteBackup();
      } catch (cleanupError) {
        throw StateError('$acquisitionError; cleanup failed: $cleanupError');
      }
      rethrow;
    }
  }

  Future<void> _registerRunOnceRecovery() async {
    final executable =
        _recoveryExecutableOverride ?? Platform.resolvedExecutable;
    final encodedExecutable = base64Encode(utf8.encode(executable));
    final result = await _runPowerShell('''
\$runOncePath = '$_runOnceRegistryPath'
\$executable = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedExecutable'))
New-Item -Path \$runOncePath -Force | Out-Null
Set-ItemProperty -Path \$runOncePath -Name '$_runOnceValueName' -Type String `
  -Value ('"' + \$executable + '" $_recoveryOnlyArgument')
''');
    if (result.exitCode != 0) {
      throw StateError(
        _formatPowerShellError('注册 Windows 代理恢复任务失败', result),
      );
    }
  }

  Future<void> _deleteBackup() async {
    final statePath = _statePath;
    File? backupFile;
    if (statePath != null) {
      backupFile = File(statePath);
      if (await backupFile.exists()) {
        Object? terminalizeError;
        try {
          final json = jsonDecode(await backupFile.readAsString())
              as Map<String, dynamic>;
          json['_activationInProgress'] = false;
          final temp = File('$statePath.tmp');
          await temp.writeAsString(jsonEncode(json), flush: true);
          await temp.rename(statePath);
        } catch (e) {
          terminalizeError = e;
        }
        if (terminalizeError != null) {
          try {
            await backupFile.delete();
            backupFile = null;
          } catch (deleteError) {
            throw StateError(
              'Failed to terminalize or delete the Windows proxy recovery '
              'file: $terminalizeError; $deleteError',
            );
          }
        }
      }
    }

    final nativeResult = await _runPowerShell('''
\$backupPath = '$_nativeBackupRegistryPath'
if (Test-Path -LiteralPath \$backupPath) {
  \$terminalized = \$false
  \$terminalizeErrors = @()
  try {
    Set-ItemProperty -LiteralPath \$backupPath -Name Valid -Type DWord -Value 0 -ErrorAction Stop
    \$terminalized = \$true
  } catch {
    \$terminalizeErrors += \$_.Exception.Message
  }
  \$flagsTerminal = \$true
  foreach (\$name in @(
    'RestoreInProgress',
    'EndpointRestoreInProgress',
    'ActivationInProgress'
  )) {
    try {
      Set-ItemProperty -LiteralPath \$backupPath -Name \$name -Type DWord -Value 0 -ErrorAction Stop
    } catch {
      \$flagsTerminal = \$false
      \$terminalizeErrors += \$_.Exception.Message
    }
  }
  if (\$flagsTerminal) { \$terminalized = \$true }
  \$removed = \$false
  \$removeError = ''
  try {
    Remove-Item -LiteralPath \$backupPath -Recurse -Force -ErrorAction Stop
    \$removed = \$true
  } catch {
    \$removeError = \$_.Exception.Message
  }
  if (-not (\$terminalized -or \$removed)) {
    throw ('Native proxy recovery cleanup failed: ' +
      ((\$terminalizeErrors + \$removeError) -join '; '))
  }
}
''');
    if (nativeResult.exitCode != 0) {
      throw StateError(
        _formatPowerShellError(
          'Failed to terminalize Windows native proxy recovery state',
          nativeResult,
        ),
      );
    }

    final runOnceResult = await _runPowerShell('''
\$runOncePath = '$_runOnceRegistryPath'
if (Test-Path -LiteralPath \$runOncePath) {
  \$runOnce = Get-ItemProperty -LiteralPath \$runOncePath -ErrorAction Stop
  if (\$null -ne \$runOnce.PSObject.Properties['$_runOnceValueName']) {
    Remove-ItemProperty -LiteralPath \$runOncePath `
      -Name '$_runOnceValueName' -ErrorAction Stop
  }
}
''');
    if (runOnceResult.exitCode != 0) {
      throw StateError(
        _formatPowerShellError('删除 Windows 代理恢复任务失败', runOnceResult),
      );
    }
    if (backupFile != null) {
      try {
        if (await backupFile.exists()) await backupFile.delete();
      } catch (e) {
        throw StateError(
          'Failed to delete the Windows proxy recovery file: $e',
        );
      }
    }
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
