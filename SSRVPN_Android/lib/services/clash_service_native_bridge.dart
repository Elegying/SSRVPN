part of 'clash_service.dart';

const _nativeStateRetryDelays = <Duration>[
  Duration(milliseconds: 100),
  Duration(milliseconds: 300),
];

// Align deferred reconciliation with the native liveness cadence. A failed
// platform-channel read must not create a tight, indefinite polling loop.
const _deferredNativeStateRetryDelay = Duration(seconds: 3);

class AndroidProxySwitchResult {
  const AndroidProxySwitchResult({
    required this.liveSwitched,
    required this.snapshotPersisted,
    required this.intentCurrent,
    this.nativeSessionGeneration,
    this.runtimeNodeName,
  });

  final bool liveSwitched;
  final bool snapshotPersisted;
  final bool intentCurrent;
  final int? nativeSessionGeneration;
  final String? runtimeNodeName;
}

typedef _NativeConnectionState = ({
  bool running,
  bool transitioning,
  String? protectedConfigPath,
  int? sessionGeneration,
});

extension AndroidNativeBridge on ClashService {
  Future<bool> _recoverNativeAfterHealthCheckFailure(
    int connectionGeneration,
  ) async {
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      await stop();
      return false;
    }
    if (await healthCheck()) {
      setRunning(true);
      return true;
    }
    if (!_healthRecoveryPolicy.tryAcquire()) {
      await stop();
      return false;
    }

    final activeConfigPath =
        _runningConfigPath ?? _nativeSnapshotConfigPath ?? configPath;
    _notifyNativeRuntimeNotice('Mihomo 持续失去响应，正在执行一次安全重启…');
    try {
      await stop();
    } catch (error) {
      log('健康检查恢复时停止 Mihomo 失败: $error');
      return false;
    }
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      return false;
    }
    if (activeConfigPath.isEmpty || !File(activeConfigPath).existsSync()) {
      setLastStartError('自动恢复所需的运行配置已不存在');
      return false;
    }
    return _start(
      preparedConfigPath: activeConfigPath,
      automaticRecovery: true,
    );
  }

  void _clearStopOperation(Future<void> operation) {
    if (identical(_stopOperation, operation)) _stopOperation = null;
  }

  Future<void> _notifyNativeStateChange() async {
    try {
      await ClashService._channel
          .invokeMethod('notifyVpnStateChanged')
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      log('通知原生 VPN 状态失败: $e');
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'autoConnect') {
      log('收到原生自动连接请求');
      onAutoConnect?.call();
      return;
    }
    if (call.method != 'vpnStateChanged') return;
    await _handleNativeStateChanged(call.arguments == true);
  }

  @visibleForTesting
  Future<void> handleNativeStateChangedForTesting(bool connected) =>
      _handleNativeStateChanged(connected);

  Future<void> _handleNativeStateChanged(bool connected) async {
    _nativeStateReconciliationTimer?.cancel();
    _nativeStateReconciliationTimer = null;
    final nativeStateEpoch = ++_nativeStateEpoch;
    final startGeneration = _startGeneration;
    final connectionWasDesired = connectionDesired;
    final connectionGeneration = captureAutomaticRestartIntent();
    bool reconciliationIsCurrent() =>
        nativeStateEpoch == _nativeStateEpoch &&
        startGeneration == _startGeneration &&
        (connectionWasDesired
            ? connectionGeneration != null &&
                isConnectionIntentCurrent(
                  connectionGeneration,
                  connected: true,
                )
            : !connectionDesired);
    final synchronized = await _refreshNativeConnectionState(
      nativeStateEpoch,
      source: '原生通知',
      isStillCurrent: reconciliationIsCurrent,
    );
    if (!reconciliationIsCurrent() || synchronized) return;

    // Broadcast booleans omit the authoritative `transitioning` bit and can
    // arrive late. They are wake-up hints only: retry the complete snapshot,
    // then use isCoreRunning solely as a positive degraded confirmation.
    log('原生通知 VPN 状态=$connected，但会话状态查询失败，正在有限重试');
    final synchronizedAfterRetry = await _retryNativeStateSync(
      nativeStateEpoch,
      isStillCurrent: reconciliationIsCurrent,
    );
    if (!reconciliationIsCurrent() || synchronizedAfterRetry) return;

    final nativeRunning = await _queryNativeRunningState();
    if (!reconciliationIsCurrent()) return;
    if (nativeRunning == true) {
      _applyNativeRunningFallback(source: '原生运行状态降级确认');
      return;
    }

    // `false` cannot distinguish a terminal stop from the native recovery gap,
    // so keep the last trusted state and retry at a low frequency until a full
    // snapshot arrives or a newer intent/broadcast invalidates this epoch.
    _scheduleDeferredNativeStateSync(
      nativeStateEpoch,
      isStillCurrent: reconciliationIsCurrent,
    );
  }

  Future<bool> _retryNativeStateSync(
    int nativeStateEpoch, {
    required bool Function() isStillCurrent,
  }) async {
    for (final delay in _nativeStateRetryDelays) {
      await Future<void>.delayed(delay);
      if (!isStillCurrent()) return false;
      final synchronized = await _refreshNativeConnectionState(
        nativeStateEpoch,
        source: '原生状态重试',
        isStillCurrent: isStillCurrent,
      );
      if (!isStillCurrent()) return false;
      if (synchronized) return true;
    }
    return false;
  }

  void _scheduleDeferredNativeStateSync(
    int nativeStateEpoch, {
    required bool Function() isStillCurrent,
  }) {
    _nativeStateReconciliationTimer?.cancel();
    _nativeStateReconciliationTimer = Timer(
      _deferredNativeStateRetryDelay,
      () async {
        _nativeStateReconciliationTimer = null;
        if (!isStillCurrent()) return;
        final synchronized = await _refreshNativeConnectionState(
          nativeStateEpoch,
          source: '原生状态低频复核',
          isStillCurrent: isStillCurrent,
        );
        if (!synchronized && isStillCurrent()) {
          _scheduleDeferredNativeStateSync(
            nativeStateEpoch,
            isStillCurrent: isStillCurrent,
          );
        }
      },
    );
  }

  void _applyNativeRunningFallback({required String source}) {
    final changed = !isRunning || _nativeConnectionTransitioning;
    final adoptedIntent = !connectionDesired;
    _nativeSessionProtocolAvailable = false;
    _nativeConnectionTransitioning = false;
    _nativeSessionGeneration = null;
    if (adoptedIntent) requestConnectionIntent(true);
    setRunning(true);
    startStatusMonitor();
    log('$source: VPN 已连接（完整会话详情等待同步）');
    if (changed || adoptedIntent) notifyStatusChanged();
  }

  Future<void> _syncNativeState() async {
    await refreshNativeConnectionState(source: '启动同步');
  }

  /// Refreshes the native VPN session as one authoritative state snapshot.
  ///
  /// Native recovery deliberately reports `running=false` while keeping
  /// `transitioning=true`. Consumers must never publish the running flag
  /// before this method has also applied the transition bit.
  Future<bool> refreshNativeConnectionState({String source = '主动同步'}) {
    final nativeStateEpoch = ++_nativeStateEpoch;
    return _refreshNativeConnectionState(
      nativeStateEpoch,
      source: source,
    );
  }

  Future<bool> _refreshNativeConnectionState(
    int nativeStateEpoch, {
    required String source,
    bool Function()? isStillCurrent,
  }) async {
    final state = await _queryNativeConnectionState();
    if (state == null ||
        nativeStateEpoch != _nativeStateEpoch ||
        isStillCurrent?.call() == false) {
      return false;
    }
    _applyNativeConnectionState(state, source: source);
    return true;
  }

  void _applyNativeConnectionState(
    _NativeConnectionState state, {
    required String source,
  }) {
    final nativeWasRunning = isRunning;
    final recoveryWasObserved = _nativeConnectionTransitioning;
    final dartOwnsStart = _startOperation != null;
    final dartOwnsStop = _stopOperation != null;
    final statusChanged = isRunning != state.running;
    final transitionChanged =
        _nativeConnectionTransitioning != state.transitioning;
    final sessionChanged =
        _nativeSessionGeneration != state.sessionGeneration ||
            _runningConfigPath != state.protectedConfigPath;
    _nativeSessionProtocolAvailable = true;
    _nativeConnectionTransitioning = state.transitioning;
    _runningConfigPath = state.protectedConfigPath;
    _nativeSessionGeneration = state.sessionGeneration;

    if (state.running &&
        !connectionDesired &&
        !dartOwnsStart &&
        !dartOwnsStop) {
      // A quick tile or a surviving native session can exist before this Dart
      // process has a connection intent. Adopt it so a later recovery remains
      // cancellable from the application UI.
      requestConnectionIntent(true);
    }
    final terminalUnexpectedStop = !state.running &&
        !state.transitioning &&
        connectionDesired &&
        !dartOwnsStart &&
        !dartOwnsStop &&
        (nativeWasRunning || recoveryWasObserved);
    if (state.running) {
      setRunning(true);
      startStatusMonitor();
    } else {
      stopStatusMonitor();
      if (terminalUnexpectedStop) {
        _markNativeConnectionLost();
      } else {
        setRunning(false);
      }
    }

    if (statusChanged || transitionChanged) {
      if (state.running) {
        log('$source: VPN 已连接');
      } else if (state.transitioning) {
        log('$source: VPN 核心正在自动恢复');
      } else {
        log('$source: VPN 已断开');
      }
    }
    if (!terminalUnexpectedStop &&
        (statusChanged || transitionChanged || sessionChanged)) {
      notifyStatusChanged();
    }
  }

  Future<bool> _ensureNativeSessionForMutation() async {
    if (_nativeSessionProtocolAvailable) {
      return isRunning && _nativeSessionGeneration != null;
    }
    final state = await _queryNativeConnectionState();
    if (state == null || !state.running || state.sessionGeneration == null) {
      if (state != null) {
        _applyNativeConnectionState(state, source: '会话校验');
      }
      return false;
    }
    _applyNativeConnectionState(state, source: '会话校验');
    return true;
  }

  Future<bool> _isNativeSessionCurrent(int expectedGeneration) async {
    final state = await _queryNativeConnectionState();
    if (state != null) {
      _applyNativeConnectionState(state, source: '会话校验');
      return state.running && state.sessionGeneration == expectedGeneration;
    }
    return false;
  }

  Future<bool?> _queryNativeRunningState() async {
    try {
      return await ClashService._channel
          .invokeMethod<bool>('isCoreRunning')
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      log('查询原生 VPN 状态失败: $e');
      return null;
    }
  }

  Future<_NativeConnectionState?> _queryNativeConnectionState() async {
    try {
      final value = await ClashService._channel
          .invokeMethod<Object?>('getConnectionState')
          .timeout(const Duration(seconds: 3));
      return _parseNativeConnectionState(value);
    } catch (e) {
      log('查询原生 VPN 会话状态失败: $e');
      return null;
    }
  }

  Future<_NativeConnectionState?> _parseNativeConnectionState(
    Object? value,
  ) async {
    if (value is! Map) return null;
    final running = value['running'] == true;
    final transitioning = value['transitioning'] == true;
    final sessionGeneration = (value['sessionGeneration'] as num?)?.toInt();
    final rawPath = value['protectedConfigPath'] as String?;
    if (rawPath == null || rawPath.isEmpty) {
      return (
        running: running,
        transitioning: transitioning,
        protectedConfigPath: null,
        sessionGeneration: sessionGeneration,
      );
    }
    final file = File(rawPath).absolute;
    final name = file.uri.pathSegments.last;
    final supportedName = name == 'config.yaml' ||
        (name.startsWith('config-') && name.endsWith('.yaml'));
    if (!supportedName ||
        file.parent.path != Directory(configDir).absolute.path ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      log('原生 VPN 返回了无效的受保护配置路径');
      return (
        running: running,
        transitioning: transitioning,
        protectedConfigPath: null,
        sessionGeneration: sessionGeneration,
      );
    }
    return (
      running: running,
      transitioning: transitioning,
      protectedConfigPath: file.path,
      sessionGeneration: sessionGeneration,
    );
  }

  Future<bool> consumePendingAutoConnect() async {
    try {
      final pending = await ClashService._channel.invokeMethod<bool>(
        'consumePendingAutoConnect',
      );
      return pending == true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _getNativeLibraryDir() async {
    try {
      final result = await ClashService._channel.invokeMethod<String>(
        'getNativeLibraryDir',
      );
      if (result != null && result.isNotEmpty) return result;
    } catch (e) {
      log('MethodChannel getNativeLibraryDir 失败: $e');
    }
    for (final dir in ['/data/app/~~/lib/arm64', '/data/app/lib/arm64']) {
      if (Directory(dir).existsSync()) {
        for (final entity in Directory(dir).listSync()) {
          if (entity.path.contains('libgojni')) return dir;
        }
      }
    }
    return '/data/app/lib/arm64';
  }
}
