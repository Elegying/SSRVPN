part of 'clash_service.dart';

extension _WindowsUnexpectedExitScheduling on _WindowsCoreLifecycle {
  void _scheduleUnexpectedExitRecovery(
    int? generation,
    int exitCode,
    Future<Set<WindowsTunInterfaceIdentity>>? tunInterfaces,
  ) {
    final cleanup = _prepareUnexpectedExitProxyCleanup(
      generation,
      usedSystemProxy: tunInterfaces == null,
    );
    final operation = cleanup.then<void>((_) {});
    _exitCleanupOperation = operation;
    cleanup.then((proxyCleanup) {
      if (identical(_exitCleanupOperation, operation)) {
        _exitCleanupOperation = null;
      }
      unawaited(
        _recoverFromUnexpectedExit(
          generation,
          exitCode,
          proxyCleanup,
          tunInterfaces,
        ),
      );
    });
  }

  Future<DesktopUnexpectedExitProxyCleanupResult>
      _prepareUnexpectedExitProxyCleanup(
    int? generation, {
    required bool usedSystemProxy,
  }) async {
    SystemProxyOwnershipStatus? ownershipBeforeClear;
    if (usedSystemProxy) {
      try {
        ownershipBeforeClear = await inspectSystemProxyOwnership();
      } catch (error) {
        ownershipBeforeClear = SystemProxyOwnershipStatus.unavailable;
        log('⚠️ 核心异常退出前无法确认系统代理所有权: $error');
      }
      if (ownershipBeforeClear != SystemProxyOwnershipStatus.owned &&
          generation != null &&
          isConnectionIntentCurrent(generation, connected: true)) {
        // Cleanup/discard remains allowed, but invalidate automatic restart
        // before the asynchronous registry transaction can race with it.
        _markUnexpectedExitConnectionLost();
      }
    }

    final proxyCleared = await retryUnexpectedExitSystemProxyRecovery(
      clearProxy: clearSystemProxyAfterUnexpectedExit,
      onAttemptFailed: (attempt, totalAttempts) {
        log('⚠️ 核心退出后的系统代理恢复未完成 ($attempt/$totalAttempts)');
      },
    );
    final ownershipChangedDuringClear =
        usedSystemProxy && systemProxyOwnershipChangedSinceLastAcquisition;
    if (ownershipChangedDuringClear &&
        generation != null &&
        isConnectionIntentCurrent(generation, connected: true)) {
      _markUnexpectedExitConnectionLost();
    }
    return DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: proxyCleared,
      ownershipBeforeClear: ownershipBeforeClear,
      ownershipChangedDuringClear: ownershipChangedDuringClear,
    );
  }
}
