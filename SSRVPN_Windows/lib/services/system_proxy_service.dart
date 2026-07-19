import 'dart:async';
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
    Duration pendingCommandExitTimeout = const Duration(seconds: 20),
  })  : _isWindows = isWindows ?? Platform.isWindows,
        _scriptRunner = scriptRunner,
        _localAppDataOverride = localAppData,
        _recoveryExecutableOverride = recoveryExecutable,
        _pendingCommandExitTimeout = pendingCommandExitTimeout;

  factory SystemProxyService.forTesting({
    required bool isWindows,
    required SystemProxyScriptRunner scriptRunner,
    String localAppData = '',
    String? recoveryExecutable,
    Duration pendingCommandExitTimeout = const Duration(seconds: 20),
  }) =>
      SystemProxyService._(
        isWindows: isWindows,
        scriptRunner: scriptRunner,
        localAppData: localAppData,
        recoveryExecutable: recoveryExecutable,
        pendingCommandExitTimeout: pendingCommandExitTimeout,
      );

  final bool _isWindows;
  final SystemProxyScriptRunner? _scriptRunner;
  final String? _localAppDataOverride;
  final String? _recoveryExecutableOverride;
  final Duration _pendingCommandExitTimeout;

  bool _proxyEnabled = false;
  bool _ownsProxy = false;
  bool _recoveryPending = false;
  bool _endpointSafeWithPendingRecovery = false;
  String? _dataDir;
  Future<bool>? _recoveryOperation;
  final ConnectionTransitionQueue _transactionQueue =
      ConnectionTransitionQueue();
  Future<int>? _pendingCancelledProxyCommandExit;
  bool _preparedAcquisitionNeedsDiscard = false;
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
    if (!await _awaitPendingCancelledProxyCommandExit()) return;
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
        if (!await _awaitPendingCancelledProxyCommandExit()) return;
        if (_preparedAcquisitionNeedsDiscard) {
          await _discardPreparedAcquisition(null);
          return;
        }
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
        final current = await _readCurrentProxy();
        if (current == null) {
          _recoveryPending = true;
          _lastError ??= '无法读取当前 Windows 系统代理设置，稍后重试恢复';
          return;
        }
        final recoveryAction = await _classifyRecoveryAction(
          current: current,
          snapshot: snapshot,
          ownedProxyServer: ownedProxyServer,
        );
        if (recoveryAction == _ProxyRecoveryAction.unavailable) {
          _recoveryPending = true;
          _lastError ??= '无法读取 Windows 原生代理恢复阶段，稍后重试恢复';
          return;
        }
        if (recoveryAction == _ProxyRecoveryAction.discard) {
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
        final restored = recoveryAction == _ProxyRecoveryAction.restoreFull
            ? await _restoreSnapshot(snapshot)
            : await _restoreOwnedEndpoint(snapshot);
        if (restored) {
          try {
            await _deleteBackup();
            _forgetOwnership();
            _recoveryPending = false;
          } on ProcessTerminationNotConfirmedException {
            rethrow;
          } catch (cleanupError) {
            await _finishFailedClearIfEndpointSafe(
              '上次异常退出后的系统代理已恢复，但恢复日志清理失败: '
              '$cleanupError',
            );
          }
        } else {
          await _markIncompleteRestorePending(
            '上次异常退出后的系统代理设置未能恢复',
          );
        }
      });
    } on ProcessTerminationNotConfirmedException catch (error) {
      _deferRecoveryUntilProcessExit(
        error,
        context: '恢复 Windows 系统代理',
        recoveryStateExists: true,
      );
    } catch (e) {
      // Keep the backup for a future retry instead of deleting recovery data.
      _recoveryPending = true;
      _lastError = '读取系统代理恢复文件失败: $e';
    }
  }

  /// Retries startup recovery after a transient registry/PowerShell failure.
  /// The backup is never discarded merely to make a new connection possible.
  Future<bool> retryPendingRecovery() {
    if (!_recoveryPending && _pendingCancelledProxyCommandExit == null) {
      return Future<bool>.value(true);
    }
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
    if (!await _awaitPendingCancelledProxyCommandExit()) return false;
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

  Future<bool> setSystemProxy(
    String host,
    int port, {
    Future<void>? cancellation,
  }) async {
    if (!_isWindows) return false;
    if (!await _awaitPendingCancelledProxyCommandExit()) return false;
    final cancellationSignal = _SystemProxyAcquisitionCancellation(
      cancellation,
    );
    try {
      return await _withProxyTransactionLock(
        () async {
          if (!await _awaitPendingCancelledProxyCommandExit()) return false;
          return _setSystemProxyUnlocked(host, port, cancellationSignal);
        },
      );
    } on _SystemProxyAcquisitionCancelled {
      _lastError = '设置 Windows 系统代理已取消';
      return false;
    } catch (e) {
      _lastError = '系统代理事务锁失败: $e';
      return false;
    }
  }

  Future<bool> isCurrentSystemProxyOwned() async {
    if (!_isWindows) return false;
    if (!await _awaitPendingCancelledProxyCommandExit()) return false;
    try {
      return await _withProxyTransactionLock(
        () async {
          if (!await _awaitPendingCancelledProxyCommandExit()) return false;
          return _isCurrentSystemProxyOwnedUnlocked();
        },
      );
    } on ProcessTerminationNotConfirmedException catch (error) {
      _deferRecoveryUntilProcessExit(
        error,
        context: '检查 Windows 系统代理状态',
        recoveryStateExists: _ownsProxy || _recoveryPending,
      );
      return false;
    } catch (e) {
      _lastError = '系统代理状态检查失败: $e';
      return false;
    }
  }

  Future<bool> _isCurrentSystemProxyOwnedUnlocked({
    Future<void>? cancellation,
  }) async {
    if (!_ownsProxy) {
      _lastError = 'SSRVPN 当前未持有 Windows 系统代理';
      return false;
    }
    final current = await _readCurrentProxy(cancellation: cancellation);
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

  Future<bool> _setSystemProxyUnlocked(
    String host,
    int port,
    _SystemProxyAcquisitionCancellation cancellation,
  ) async {
    if (!_isWindows) return false;
    _lastError = null;
    var preparedThisAttempt = false;
    var proxyMutationStarted = false;
    if (_recoveryPending) {
      _lastError = '系统代理仍有未恢复的旧状态，请查看运行日志';
      return false;
    }
    if (!_isValidHost(host) || port < 1 || port > 65535) {
      _lastError = '代理地址或端口无效: $host:$port';
      return false;
    }

    try {
      cancellation.throwIfRequested();
      if (!await isLauncherGuardianReady(
        cancellation: cancellation.future,
      )) {
        cancellation.throwIfRequested();
        _lastError = '独立系统代理保护未就绪，请通过 ssrvpn_windows.exe 启动或重试';
        return false;
      }
      cancellation.throwIfRequested();
      final proxyServer = '$host:$port';
      if (_ownsProxy && _ownedProxyServer != proxyServer) {
        // Release the old endpoint before acquiring a different one so the
        // recovery record always names the proxy that is actually installed.
        if (!await _clearSystemProxyUnlocked()) return false;
        cancellation.throwIfRequested();
        _lastError = null;
      }
      if (!_ownsProxy) {
        final snapshot = await _readCurrentProxy(
          cancellation: cancellation.future,
        );
        cancellation.throwIfRequested();
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
        preparedThisAttempt = true;
        await _writeBackup(
          snapshot,
          proxyServer,
          cancellation: cancellation,
        );
        cancellation.throwIfRequested();
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

      // From this point onward the PowerShell command may have changed the
      // user's live proxy even if it later fails or is cancelled.
      proxyMutationStarted = true;
      final result = await _runPowerShell(
        script,
        cancellation: cancellation.future,
      );
      if (result.exitCode == 125) {
        throw const _SystemProxyAcquisitionCancelled();
      }
      cancellation.throwIfRequested();
      if (result.exitCode != 0) {
        final setError = _formatPowerShellError('写入 Windows 系统代理失败', result);
        return _rollbackFailedAcquisition(setError);
      }
      try {
        await _markActivationComplete(cancellation: cancellation);
        cancellation.throwIfRequested();
      } catch (e) {
        if (e is _SystemProxyAcquisitionCancelled ||
            e is ProcessTerminationNotConfirmedException) {
          rethrow;
        }
        return _rollbackFailedAcquisition('提交 Windows 系统代理状态失败: $e');
      }

      if (!await _isCurrentSystemProxyOwnedUnlocked(
        cancellation: cancellation.future,
      )) {
        cancellation.throwIfRequested();
        final verificationError = _lastError ?? '无法确认 Windows 系统代理已生效';
        final released = await _clearSystemProxyUnlocked();
        final releaseError = _lastError;
        _lastError = released || releaseError == null
            ? verificationError
            : '$verificationError；$releaseError';
        return false;
      }
      cancellation.throwIfRequested();

      _proxyEnabled = true;
      return true;
    } on ProcessTerminationNotConfirmedException catch (error) {
      if (preparedThisAttempt && !proxyMutationStarted) {
        _preparedAcquisitionNeedsDiscard = true;
      }
      _deferRecoveryUntilProcessExit(
        error,
        context: '设置 Windows 系统代理',
        recoveryStateExists:
            _ownsProxy || preparedThisAttempt || proxyMutationStarted,
      );
      return false;
    } on _SystemProxyAcquisitionCancelled {
      const setError = '设置 Windows 系统代理已取消';
      if (proxyMutationStarted) {
        return _rollbackFailedAcquisition(setError);
      }
      if (preparedThisAttempt) {
        await _discardPreparedAcquisition(setError);
        return false;
      }
      _lastError = setError;
      return false;
    } catch (e) {
      final setError = '设置 Windows 系统代理异常: $e';
      if (proxyMutationStarted) {
        return _rollbackFailedAcquisition(setError);
      }
      if (preparedThisAttempt) {
        await _discardPreparedAcquisition(setError);
        return false;
      }
      _lastError = setError;
      return false;
    }
  }

  /// Restores the values captured before SSRVPN enabled its proxy.
  Future<bool> clearSystemProxy() async {
    if (!_isWindows) return false;
    if (!await _awaitPendingCancelledProxyCommandExit()) return false;
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
      return await _withProxyTransactionLock(() async {
        if (!await _awaitPendingCancelledProxyCommandExit()) return false;
        if (_preparedAcquisitionNeedsDiscard) {
          final discarded = await _discardPreparedAcquisition(null);
          if (discarded) _preparedAcquisitionNeedsDiscard = false;
          return discarded;
        }
        return _clearSystemProxyUnlocked();
      });
    } on ProcessTerminationNotConfirmedException catch (error) {
      _deferRecoveryUntilProcessExit(
        error,
        context: '恢复 Windows 系统代理',
        recoveryStateExists: true,
      );
      return false;
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

    var liveRecoveryComplete = false;
    try {
      final current = await _readCurrentProxy();
      if (current == null) {
        _recoveryPending = true;
        _lastError ??= '无法读取当前 Windows 系统代理设置，稍后重试恢复';
        return false;
      }
      final recoveryAction = await _classifyRecoveryAction(
        current: current,
        snapshot: snapshot,
        ownedProxyServer: _ownedProxyServer,
      );
      if (recoveryAction == _ProxyRecoveryAction.unavailable) {
        _recoveryPending = true;
        _lastError ??= '无法读取 Windows 原生代理恢复阶段，稍后重试恢复';
        return false;
      }
      if (recoveryAction == _ProxyRecoveryAction.discard) {
        liveRecoveryComplete = true;
        await _deleteBackup();
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }

      final restored = recoveryAction == _ProxyRecoveryAction.restoreFull
          ? await _restoreSnapshot(snapshot)
          : await _restoreOwnedEndpoint(snapshot);
      if (!restored) {
        return _markIncompleteRestorePending(
          _lastError ??
              (recoveryAction == _ProxyRecoveryAction.restoreEndpoint
                  ? '释放 SSRVPN 系统代理端点失败'
                  : '恢复原 Windows 系统代理设置失败'),
        );
      }
      liveRecoveryComplete = true;
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      return true;
    } on ProcessTerminationNotConfirmedException catch (error) {
      _deferRecoveryUntilProcessExit(
        error,
        context: '恢复 Windows 系统代理',
        recoveryStateExists: true,
      );
      return false;
    } catch (e) {
      final error = '恢复 Windows 系统代理异常: $e';
      return liveRecoveryComplete
          ? _finishFailedClearIfEndpointSafe(error)
          : _markIncompleteRestorePending(error);
    }
  }

  Future<bool> _markIncompleteRestorePending(String error) async {
    _recoveryPending = true;
    _endpointSafeWithPendingRecovery = false;
    _ProxySnapshot? current;
    try {
      current = await _readCurrentProxy();
    } on ProcessTerminationNotConfirmedException catch (terminationError) {
      _deferRecoveryUntilProcessExit(
        terminationError,
        context: '确认 Windows 系统代理恢复进度',
        recoveryStateExists: true,
      );
      return false;
    } catch (readError) {
      _lastError = '$error；无法确认当前 Windows 系统代理状态: $readError';
      return false;
    }
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
    _endpointSafeWithPendingRecovery = true;
    _lastError = '$error；SSRVPN 代理端点已安全释放，但原设置尚未完整恢复';
    return false;
  }

  Future<bool> _finishFailedClearIfEndpointSafe(String error) async {
    _recoveryPending = true;
    _endpointSafeWithPendingRecovery = false;
    _ProxySnapshot? current;
    try {
      current = await _readCurrentProxy();
    } on ProcessTerminationNotConfirmedException catch (terminationError) {
      _deferRecoveryUntilProcessExit(
        terminationError,
        context: '确认 Windows 系统代理安全状态',
        recoveryStateExists: true,
      );
      return false;
    } catch (readError) {
      _lastError = '$error；无法确认当前 Windows 系统代理状态: $readError';
      return false;
    }
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
    } on ProcessTerminationNotConfirmedException catch (terminationError) {
      _deferRecoveryUntilProcessExit(
        terminationError,
        context: '确认 Windows 系统代理安全状态',
        recoveryStateExists: true,
      );
      return false;
    } catch (cleanupError) {
      _endpointSafeWithPendingRecovery = true;
      _lastError = '$error；SSRVPN 代理端点已安全释放，但恢复日志仍待清理: '
          '$cleanupError';
      return false;
    }
  }

  bool _isCurrentProxyEndpointSafeToStop(_ProxySnapshot current) {
    final previousProxy = _previousProxy;
    if (previousProxy != null &&
        current.toWindowsProxyState() == previousProxy.toWindowsProxyState()) {
      return true;
    }
    if (current.proxyEnable == 0) return true;
    if (current.proxyEnable != 1 || !current.hasProxyServer) return false;
    final ownedProxyServer = _ownedProxyServer;
    if (ownedProxyServer == null || ownedProxyServer.isEmpty) return false;
    return current.proxyServer != ownedProxyServer;
  }

  Future<T> _withProxyTransactionLock<T>(Future<T> Function() operation) =>
      _transactionQueue.run(() async {
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
      });

  bool _isValidHost(String host) => RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host);

  Future<bool> isLauncherGuardianReady({Future<void>? cancellation}) async {
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
''', cancellation: cancellation);
      return result.exitCode == 0;
    } on ProcessTerminationNotConfirmedException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _rollbackFailedAcquisition(String setError) async {
    _recoveryPending = true;
    var restoreCompleted = false;
    try {
      final snapshot = _previousProxy;
      final restored = snapshot != null && await _restoreSnapshot(snapshot);
      if (!restored) {
        final restoreError = _lastError;
        final combinedError =
            restoreError == null ? setError : '$setError；$restoreError';
        await _markIncompleteRestorePending(combinedError);
        return false;
      }
      restoreCompleted = true;
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      _lastError = setError;
    } on ProcessTerminationNotConfirmedException catch (error) {
      _deferRecoveryUntilProcessExit(
        error,
        context: '回滚 Windows 系统代理',
        recoveryStateExists: true,
      );
    } catch (e) {
      final error = '$setError；恢复状态清理失败: $e';
      if (restoreCompleted) {
        await _finishFailedClearIfEndpointSafe(error);
      } else {
        await _markIncompleteRestorePending(error);
      }
    }
    return false;
  }

  Future<bool> _discardPreparedAcquisition(String? error) async {
    try {
      await _deleteBackup();
      _forgetOwnership();
      _recoveryPending = false;
      _lastError = error;
      return true;
    } on ProcessTerminationNotConfirmedException catch (terminationError) {
      _preparedAcquisitionNeedsDiscard = true;
      _deferRecoveryUntilProcessExit(
        terminationError,
        context: '清理 Windows 系统代理准备状态',
        recoveryStateExists: true,
      );
      return false;
    } catch (cleanupError) {
      _recoveryPending = true;
      final prefix = error == null ? '' : '$error；';
      _lastError = '$prefix未启用系统代理，但准备状态清理失败: $cleanupError';
      return false;
    }
  }

  void _deferRecoveryUntilProcessExit(
    ProcessTerminationNotConfirmedException error, {
    required String context,
    required bool recoveryStateExists,
  }) {
    _trackPendingCancelledProxyCommand(error.processExit);
    if (recoveryStateExists) _recoveryPending = true;
    _lastError = '$context时无法确认中断的 PowerShell 已退出；'
        '${recoveryStateExists ? "已保留恢复状态，" : ""}确认退出前不会启动新的代理事务';
  }

  void _trackPendingCancelledProxyCommand(Future<int> processExit) {
    _pendingCancelledProxyCommandExit = processExit;
    processExit.then<void>(
      (_) {
        if (identical(_pendingCancelledProxyCommandExit, processExit)) {
          _pendingCancelledProxyCommandExit = null;
        }
      },
      onError: (_, __) {},
    );
  }

  Future<bool> _awaitPendingCancelledProxyCommandExit() async {
    final pending = _pendingCancelledProxyCommandExit;
    if (pending == null) return true;
    try {
      await pending.timeout(_pendingCommandExitTimeout);
      if (identical(_pendingCancelledProxyCommandExit, pending)) {
        _pendingCancelledProxyCommandExit = null;
      }
      return true;
    } on TimeoutException {
      if (_ownsProxy) _recoveryPending = true;
      _lastError = '上一个已取消的 Windows 代理命令仍未确认退出；'
          '为避免与恢复操作并发，暂不修改系统代理';
      return false;
    } catch (error) {
      if (_ownsProxy) _recoveryPending = true;
      _lastError = '等待已取消的 Windows 代理命令退出失败: $error';
      return false;
    }
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

  WindowsProxyState? _ownedProxyState(String? ownedProxyServer) {
    if (ownedProxyServer == null || ownedProxyServer.isEmpty) return null;
    return WindowsProxyState(
      hasProxyEnable: true,
      proxyEnable: 1,
      hasProxyServer: true,
      proxyServer: ownedProxyServer,
      hasProxyOverride: true,
      proxyOverride: _ownedProxyOverride,
      hasAutoConfigUrl: false,
      autoConfigUrl: '',
      hasAutoDetect: true,
      autoDetect: 0,
    );
  }

  Future<_ProxyRecoveryAction> _classifyRecoveryAction({
    required _ProxySnapshot current,
    required _ProxySnapshot snapshot,
    required String? ownedProxyServer,
  }) async {
    if (_isOwnedProxy(current, ownedProxyServer)) {
      return _ProxyRecoveryAction.restoreFull;
    }
    final ownedState = _ownedProxyState(ownedProxyServer);
    if (ownedState == null) return _ProxyRecoveryAction.discard;
    final journal = await _readNativeRecoveryJournal(ownedState.proxyServer);
    if (journal == null) return _ProxyRecoveryAction.unavailable;
    final phase = journal.phase;
    if (phase != null) {
      final reachable = isReachableWindowsProxyTransactionState(
        current: current.toWindowsProxyState(),
        original: snapshot.toWindowsProxyState(),
        owned: ownedState,
        phase: phase,
      );
      if (!reachable) {
        return _isOwnedEndpoint(current, ownedProxyServer)
            ? _ProxyRecoveryAction.restoreEndpoint
            : _ProxyRecoveryAction.discard;
      }
      return phase == WindowsProxyTransactionPhase.endpointRestore
          ? _ProxyRecoveryAction.restoreEndpoint
          : _ProxyRecoveryAction.restoreFull;
    }
    if (_isOwnedEndpoint(current, ownedProxyServer)) {
      return _ProxyRecoveryAction.restoreEndpoint;
    }
    return _ProxyRecoveryAction.discard;
  }

  Future<_NativeProxyJournal?> _readNativeRecoveryJournal(
    String ownedProxyServer,
  ) async {
    final encodedServer = base64Encode(utf8.encode(ownedProxyServer));
    final encodedOverride = base64Encode(utf8.encode(_ownedProxyOverride));
    final result = await _runPowerShell('''
\$path = '$_nativeBackupRegistryPath'
if (-not (Test-Path -LiteralPath \$path)) {
  [Console]::Out.Write('TERMINAL')
  exit 0
}
\$item = Get-ItemProperty -LiteralPath \$path
\$expectedServer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedServer'))
\$expectedOverride = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedOverride'))
\$required = @('Valid', 'OwnedProxyServer', 'OwnedProxyOverride',
  'RestoreInProgress', 'EndpointRestoreInProgress', 'ActivationInProgress')
foreach (\$name in \$required) {
  if (\$null -eq \$item.PSObject.Properties[\$name]) {
    [Console]::Out.Write('TERMINAL')
    exit 0
  }
}
if ([int]\$item.Valid -ne 1 -or
    [string]\$item.OwnedProxyServer -cne \$expectedServer -or
    [string]\$item.OwnedProxyOverride -cne \$expectedOverride) {
  [Console]::Out.Write('TERMINAL')
  exit 0
}
if ([int]\$item.EndpointRestoreInProgress -eq 1 -and
    [int]\$item.RestoreInProgress -eq 0) {
  [Console]::Out.Write('ENDPOINT_RESTORE')
} elseif ([int]\$item.RestoreInProgress -eq 1 -and
    [int]\$item.EndpointRestoreInProgress -eq 0) {
  [Console]::Out.Write('FULL_RESTORE')
} elseif ([int]\$item.ActivationInProgress -eq 1 -and
    [int]\$item.RestoreInProgress -eq 0 -and
    [int]\$item.EndpointRestoreInProgress -eq 0) {
  [Console]::Out.Write('ACTIVATION')
} else {
  [Console]::Out.Write('TERMINAL')
}
''');
    if (result.exitCode != 0) {
      _lastError = _formatPowerShellError(
        '读取 Windows 原生代理恢复阶段失败',
        result,
      );
      return null;
    }
    final output = result.stdout.toString().trim();
    return switch (output) {
      'ACTIVATION' => const _NativeProxyJournal(
          WindowsProxyTransactionPhase.activation,
        ),
      'FULL_RESTORE' => const _NativeProxyJournal(
          WindowsProxyTransactionPhase.fullRestore,
        ),
      'ENDPOINT_RESTORE' => const _NativeProxyJournal(
          WindowsProxyTransactionPhase.endpointRestore,
        ),
      'TERMINAL' => const _NativeProxyJournal(null),
      _ => null,
    };
  }

  void _forgetOwnership() {
    _ownsProxy = false;
    _proxyEnabled = false;
    _endpointSafeWithPendingRecovery = false;
    _preparedAcquisitionNeedsDiscard = false;
    _previousProxy = null;
    _ownedProxyServer = null;
  }

  Future<_ProxySnapshot?> _readCurrentProxy({
    Future<void>? cancellation,
  }) async {
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
if (${!snapshot.hasProxyEnable || snapshot.proxyEnable == 0 ? r'$true' : r'$false'}) {
  Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value 0
}
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
if (${snapshot.hasProxyEnable ? r'$true' : r'$false'}) {
  Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
} else {
  Remove-ItemProperty -Path \$regPath -Name ProxyEnable -ErrorAction SilentlyContinue
}
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
if (${!snapshot.hasProxyEnable || snapshot.proxyEnable == 0 ? r'$true' : r'$false'}) {
  Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value 0
}
if (${snapshot.hasProxyServer ? r'$true' : r'$false'}) {
  \$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$server'))
  Set-ItemProperty -Path \$regPath -Name ProxyServer -Type String -Value \$value
} else {
  Remove-ItemProperty -Path \$regPath -Name ProxyServer -ErrorAction SilentlyContinue
}
if (${snapshot.hasProxyEnable ? r'$true' : r'$false'}) {
  Set-ItemProperty -Path \$regPath -Name ProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
} else {
  Remove-ItemProperty -Path \$regPath -Name ProxyEnable -ErrorAction SilentlyContinue
}
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
    String ownedProxyServer, {
    _SystemProxyAcquisitionCancellation? cancellation,
  }) async {
    cancellation?.throwIfRequested();
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
    cancellation?.throwIfRequested();
    try {
      await _writeNativeRecoveryBackup(
        snapshot,
        ownedProxyServer,
        cancellation: cancellation?.future,
      );
      cancellation?.throwIfRequested();
      await _registerRunOnceRecovery(cancellation: cancellation?.future);
      cancellation?.throwIfRequested();
    } on ProcessTerminationNotConfirmedException {
      // The interrupted command may still be mutating native journal state.
      // Keep every recovery artifact until its original process confirms exit.
      rethrow;
    } catch (acquisitionError) {
      try {
        await _deleteBackup();
      } catch (cleanupError) {
        throw StateError('$acquisitionError; cleanup failed: $cleanupError');
      }
      rethrow;
    }
  }

  Future<void> _registerRunOnceRecovery({Future<void>? cancellation}) async {
    final executable =
        _recoveryExecutableOverride ?? Platform.resolvedExecutable;
    final encodedExecutable = base64Encode(utf8.encode(executable));
    final result = await _runPowerShell('''
\$runOncePath = '$_runOnceRegistryPath'
\$executable = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedExecutable'))
New-Item -Path \$runOncePath -Force | Out-Null
Set-ItemProperty -Path \$runOncePath -Name '$_runOnceValueName' -Type String `
  -Value ('"' + \$executable + '" $_recoveryOnlyArgument')
''', cancellation: cancellation);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
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
    String ownedProxyServer, {
    Future<void>? cancellation,
  }) async {
    String encoded(String value) => base64Encode(utf8.encode(value));
    final script = '''
\$backupPath = '$_nativeBackupRegistryPath'
if (Test-Path -LiteralPath \$backupPath) {
  Remove-Item -LiteralPath \$backupPath -Recurse -Force
}
New-Item -Path \$backupPath -Force | Out-Null
Set-ItemProperty -Path \$backupPath -Name OriginalProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
Set-ItemProperty -Path \$backupPath -Name HasProxyEnable -Type DWord -Value ${snapshot.hasProxyEnable ? 1 : 0}
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
    final result = await _runPowerShell(script, cancellation: cancellation);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
    if (result.exitCode != 0) {
      throw StateError(
        _formatPowerShellError('写入 Windows 原生代理恢复状态失败', result),
      );
    }
  }

  Future<void> _markActivationComplete({
    _SystemProxyAcquisitionCancellation? cancellation,
  }) async {
    cancellation?.throwIfRequested();
    final result = await _runPowerShell('''
\$backupPath = '$_nativeBackupRegistryPath'
Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 0
''', cancellation: cancellation?.future);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
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
    cancellation?.throwIfRequested();
    json['_activationInProgress'] = false;
    final temp = File('$statePath.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(statePath);
    cancellation?.throwIfRequested();
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Future<void>? cancellation,
  }) {
    final utf8Script = windowsPowerShellUtf8Script(script);
    final override = _scriptRunner;
    if (override != null) {
      final operation = override(utf8Script);
      if (cancellation == null) return operation;
      final completion = Completer<ProcessResult>();
      operation.then<void>(
        (result) {
          if (!completion.isCompleted) completion.complete(result);
        },
        onError: (Object error, StackTrace stack) {
          if (!completion.isCompleted) completion.completeError(error, stack);
        },
      );
      cancellation.then<void>((_) {
        if (!completion.isCompleted) {
          completion.complete(ProcessResult(-1, 125, '', '命令已取消'));
        }
      });
      return completion.future;
    }
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
      cancellation: cancellation,
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

class _SystemProxyAcquisitionCancelled implements Exception {
  const _SystemProxyAcquisitionCancelled();
}

class _SystemProxyAcquisitionCancellation {
  _SystemProxyAcquisitionCancellation(this.future) {
    future?.then<void>(
      (_) => _cancelled = true,
      onError: (_, __) => _cancelled = true,
    );
  }

  final Future<void>? future;
  bool _cancelled = false;

  void throwIfRequested() {
    if (_cancelled) throw const _SystemProxyAcquisitionCancelled();
  }
}

enum _ProxyRecoveryAction {
  restoreFull,
  restoreEndpoint,
  discard,
  unavailable,
}

class _ProxySnapshot {
  const _ProxySnapshot({
    required this.hasProxyEnable,
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

  final bool hasProxyEnable;
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
      hasProxyEnable: json['hasProxyEnable'] as bool? ?? true,
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
        'hasProxyEnable': hasProxyEnable,
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

  WindowsProxyState toWindowsProxyState() => WindowsProxyState(
        hasProxyEnable: hasProxyEnable,
        proxyEnable: proxyEnable,
        hasProxyServer: hasProxyServer,
        proxyServer: proxyServer,
        hasProxyOverride: hasProxyOverride,
        proxyOverride: proxyOverride,
        hasAutoConfigUrl: hasAutoConfigUrl,
        autoConfigUrl: autoConfigUrl,
        hasAutoDetect: hasAutoDetect,
        autoDetect: autoDetect,
      );
}

class _NativeProxyJournal {
  const _NativeProxyJournal(this.phase);

  final WindowsProxyTransactionPhase? phase;
}
