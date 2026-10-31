part of 'clash_service.dart';

// Polling and output draining retain the lifecycle's generation checks.
extension _MacosCoreWatch on _MacosCoreLifecycle {
  Future<MacosNativeCoreStatus> _readNativeCoreStatus(
    MacosNativeCoreHandle handle,
  ) async {
    final value =
        await _MacosCoreLifecycle._coreProcessChannel.invokeMethod<Object?>(
      'ownedCoreStatus',
      {
        'directory': configDir,
        'expectedContents': handle.pidRecordContents,
      },
    );
    return parseMacosNativeCoreStatus(value);
  }

  void _recordNativeCoreDiagnostics(
    MacosNativeCoreStatus status, [
    List<String>? startupOutput,
  ]) {
    void record(String output, String prefix) {
      for (final line in output.split('\n')) {
        final message = line.trim();
        if (message.isEmpty) continue;
        startupOutput?.add(message);
        if (startupOutput != null && startupOutput.length > 30) {
          startupOutput.removeAt(0);
        }
        log('$prefix$message');
      }
    }

    record(status.standardOutput, '[mihomo] ');
    record(status.standardError, '[mihomo stderr] ');
  }

  void _scheduleNativeCoreStatusWatch(MacosNativeCoreHandle handle) {
    final generation = ++_nativeCoreStatusWatchGeneration;
    _wakeNativeCoreStatusWatch();
    final operation = _watchNativeCoreStatus(handle, generation);
    _nativeCoreStatusWatcher = operation;
    operation.whenComplete(() {
      if (identical(_nativeCoreStatusWatcher, operation)) {
        _nativeCoreStatusWatcher = null;
      }
    });
  }

  Future<void> _cancelNativeCoreStatusWatch() async {
    _nativeCoreStatusWatchGeneration++;
    _wakeNativeCoreStatusWatch();
    final watcher = _nativeCoreStatusWatcher;
    if (watcher != null) await watcher;
  }

  void _wakeNativeCoreStatusWatch() {
    final wakeup = _nativeCoreStatusWakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
  }

  Future<void> _watchNativeCoreStatus(
    MacosNativeCoreHandle handle,
    int generation,
  ) async {
    bool isCurrent() =>
        generation == _nativeCoreStatusWatchGeneration &&
        identical(_clashProcess, handle);

    while (isCurrent()) {
      // Native output remains bounded to 64 KiB per stream between drains.
      // The separate guardian and health monitor retain their own cadence.
      final wakeup = Completer<void>();
      _nativeCoreStatusWakeup = wakeup;
      final timer = Timer(const Duration(seconds: 1), wakeup.complete);
      await wakeup.future;
      timer.cancel();
      if (identical(_nativeCoreStatusWakeup, wakeup)) {
        _nativeCoreStatusWakeup = null;
      }
      if (!isCurrent()) return;
      MacosNativeCoreStatus status;
      try {
        status = await _readNativeCoreStatus(handle);
      } catch (error) {
        log('读取 Mihomo 原生进程状态失败: $error');
        continue;
      }
      if (!isCurrent()) return;
      _recordNativeCoreDiagnostics(status);
      if (status.isRunning) continue;

      final exitCode = status.exitCode ?? -1;
      log('Mihomo 进程已退出，退出码: $exitCode');
      final recordRemoved = await _removeOwnedCorePidRecord(
        expectedContents: handle.pidRecordContents,
      );
      if (!isCurrent()) {
        if (recordRemoved && identical(_clashProcess, handle)) {
          _clashProcess = null;
        }
        return;
      }
      _clashProcess = null;
      if (_stoppingCore) return;
      if (isRunning) {
        final recoveryGeneration = captureAutomaticRestartIntent();
        setRunning(false);
        notifyStatusChanged();
        stopStatusMonitor();
        _scheduleUnexpectedExitCleanup(
          exitCode,
          recoveryGeneration,
          // Only the non-TUN native core is watched through _clashProcess;
          // TUN lifecycle is owned by MacosTunSession.
          usedSystemProxy: true,
        );
      }
      return;
    }
  }
}
