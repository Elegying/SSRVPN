part of 'system_proxy_service.dart';

extension _WindowsNativeProxyRecovery on SystemProxyService {
  /// Runs before taking the Dart file lock: native recovery takes the same
  /// lock itself. The queue still serializes all in-process proxy mutations.
  Future<bool?> _tryNativeRecovery() => _transactionQueue.run(() async {
        if (_statePath == null) return null;
        if (_scriptRunner != null && _nativeRecovery == null) return null;
        if (!await _awaitPendingCancelledProxyCommandExit()) return false;
        _endpointSafeWithPendingRecovery = false;
        int outcome;
        try {
          outcome = await (_nativeRecovery?.call() ??
              const MethodChannel('com.ssrvpn.windows/platform_info')
                  .invokeMethod<int>('recoverSystemProxy')
                  .then((value) => value ?? 0));
        } on MissingPluginException {
          return null;
        } catch (error) {
          _recoveryPending = true;
          _lastError = 'Windows 原生代理恢复失败: $error';
          return false;
        }
        if (outcome == -1) return null;
        if (outcome & 4 != 0) _ownershipChangedSinceLastAcquisition = true;
        outcome &= ~4;
        _endpointSafeWithPendingRecovery = outcome == 2;
        if (outcome == 1) {
          _forgetOwnership();
          _recoveryPending = false;
          _lastError = null;
          return true;
        }
        _recoveryPending = true;
        if (outcome == 2) _proxyEnabled = false;
        _lastError = outcome == 2
            ? 'SSRVPN 代理端点已安全释放，但恢复日志仍待清理'
            : 'Windows 系统代理尚未安全恢复，请保持客户端打开并重试';
        return false;
      });

  Future<bool> _isLauncherGuardianReady({Future<void>? cancellation}) async {
    try {
      final result = await _runPowerShell('''
\$guardian = [System.Threading.Mutex]::OpenExisting('${SystemProxyService._launcherGuardianMutexName}')
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
}
