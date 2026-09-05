part of 'clash_service.dart';

const androidUnknownCoreStartFailure = 'CORE_START_UNKNOWN: VPN 核心启动失败';

const _nativeCoreStartFailureCategories = <String, String>{
  'CORE_START_PERMISSION': 'permission',
  'CORE_START_PORT_CONFLICT': 'port_conflict',
  'CORE_START_API_AUTH': 'api_auth',
  'CORE_START_TUN': 'tun',
  'CORE_START_CONFIG': 'config',
  'CORE_START_TIMEOUT': 'timeout',
  'CORE_START_COMPONENT': 'component',
  'CORE_START_BUSY': 'busy',
  'CORE_START_UNKNOWN': 'unknown',
};

const _nativeCoreStartFailureMessages = <String, String>{
  'CORE_START_PERMISSION': 'CORE_START_PERMISSION: VPN 核心缺少必要权限',
  'CORE_START_PORT_CONFLICT': 'CORE_START_PORT_CONFLICT: 本地代理端口已被其他程序占用',
  'CORE_START_API_AUTH': 'CORE_START_API_AUTH: 本地控制凭据不可用或与运行配置不一致',
  'CORE_START_TUN': 'CORE_START_TUN: VPN 网络保护服务异常',
  'CORE_START_CONFIG': 'CORE_START_CONFIG: VPN 配置不可用',
  'CORE_START_TIMEOUT': 'CORE_START_TIMEOUT: VPN 核心启动超时',
  'CORE_START_COMPONENT': 'CORE_START_COMPONENT: VPN 核心组件不可用，请重新安装官方版本',
  'CORE_START_BUSY': 'CORE_START_BUSY: VPN 核心正在处理上一项操作，请稍后重试',
  'CORE_START_UNKNOWN': androidUnknownCoreStartFailure,
};

const _legacyNativeCoreStartFailureMessages = <String, String>{
  'CORE_BUSY': 'CORE_START_BUSY: VPN 核心正在处理上一项操作，请稍后重试',
  'INVALID_ARGS': 'CORE_START_CONFIG: VPN 启动参数无效',
  'INVALID_CONFIG_PATH': 'CORE_START_CONFIG: VPN 配置路径不可用',
  'CORE_TIMEOUT': 'CORE_START_TIMEOUT: VPN 核心启动超时',
};

String _nativeStartFailureMessage(PlatformException error) {
  final knownMessage = _nativeCoreStartFailureMessages[error.code] ??
      _legacyNativeCoreStartFailureMessages[error.code];
  if (knownMessage != null) return knownMessage;
  return androidUnknownCoreStartFailure;
}

String _safeLogErrorCode(Object error) {
  try {
    return AppFailure.fromMessage(error).code.wireName;
  } catch (_) {
    return AppErrorCode.unknown.wireName;
  }
}

const _nativeStateRetryDelays = <Duration>[
  Duration(milliseconds: 100),
  Duration(milliseconds: 300),
];

// Align deferred reconciliation with the native liveness cadence while keeping
// a persistent platform-channel failure bounded.
const _deferredNativeStateRetryDelay = Duration(seconds: 3);
const _maxDeferredNativeStateRetryAttempts = 3;

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
  bool manuallyStopped,
  String? protectedConfigPath,
  int? sessionGeneration,
  bool? underlyingNetworkAvailable,
  bool? underlyingNetworkValidated,
});

extension AndroidNativeBridge on ClashService {
  Future<String?> _androidDiagnosticDataPlaneWarning() async {
    if (!isRunning) return null;
    final nativeState = await _queryNativeConnectionState();
    if (nativeState == null) {
      return dataPlaneConnectivityWarning ?? '暂时无法确认设备网络状态，请稍后重新检查';
    }
    if (!nativeState.running) {
      return '原生 VPN 会话已停止，外部网络状态无法确认';
    }
    if (nativeState.underlyingNetworkAvailable == false) {
      return '设备当前没有可用网络，VPN 正在等待网络恢复';
    }
    if (nativeState.underlyingNetworkAvailable == true &&
        nativeState.underlyingNetworkValidated == false) {
      return '设备网络尚未通过系统验证，VPN 正在等待网络恢复';
    }
    return dataPlaneConnectivityWarning;
  }

  Future<bool> _canReuseIdleNativeControllerPort(
    AppSettings preferred,
  ) async {
    if (isRunning ||
        _nativeConnectionTransitioning ||
        preferred.apiSecret.isEmpty ||
        settings.apiPort != preferred.apiPort ||
        settings.apiSecret != preferred.apiSecret) {
      return false;
    }
    final nativeState = await _queryNativeConnectionState();
    if (nativeState == null ||
        nativeState.running ||
        nativeState.transitioning ||
        nativeState.protectedConfigPath != null ||
        nativeState.sessionGeneration != null) {
      return false;
    }
    try {
      return await healthCheck();
    } catch (_) {
      return false;
    }
  }

  void _clearStartOperation(Future<bool> operation) {
    if (identical(_startOperation, operation)) _startOperation = null;
  }

  void _ensureStartCurrent(int startToken) {
    if (startToken != _startGeneration) throw _AndroidStartCancelled();
  }

  bool _acceptNativeStartState(
    Object? rawState,
    _NativeConnectionState? parsedState,
  ) {
    if (rawState is! Map) return true;
    if (parsedState == null) {
      setLastStartError('无法确认原生 VPN 启动状态，请重新连接');
      return false;
    }
    if (parsedState.running && parsedState.protectedConfigPath == null) {
      setLastStartError('原生 VPN 缺少可信受保护配置，请重新连接');
      return false;
    }
    return true;
  }

  Future<bool> _rollbackMalformedNativeStartState() async {
    final malformedStateError = lastStartError ?? '无法确认原生 VPN 启动状态，请重新连接';
    try {
      await stop();
      setLastStartError('$malformedStateError，VPN 已安全回滚');
    } catch (stopError) {
      log('原生 VPN 安全回滚失败: cause=${_safeLogErrorCode(stopError)}');
      setLastStartError('$malformedStateError；安全回滚未完成，请重新打开应用后重试');
    }
    return false;
  }

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
    _notifyNativeRuntimeNotice(
      RuntimeNotice.progress(
        '连接服务持续失去响应，正在执行安全重启'
        '（${_healthRecoveryPolicy.attempts}/${_healthRecoveryPolicy.maxAttempts}）…',
      ),
    );
    try {
      await stop();
    } catch (error) {
      log('健康检查恢复时停止 Mihomo 失败: cause=${_safeLogErrorCode(error)}');
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
      log('通知原生 VPN 状态失败: cause=${_safeLogErrorCode(e)}');
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'autoConnect') {
      await _handleAutoConnectSignal();
      return;
    }
    if (call.method != 'vpnStateChanged') return;
    await _handleNativeStateChanged(call.arguments == true);
  }

  @visibleForTesting
  Future<void> handleNativeStateChangedForTesting(bool connected) =>
      _handleNativeStateChanged(connected);

  @visibleForTesting
  Future<void> handleAutoConnectSignalForTesting() =>
      _handleAutoConnectSignal();

  Future<void> _handleAutoConnectSignal() async {
    final callback = onAutoConnect;
    // 页面尚未注册回调时保留 pending，交给初始化路径稍后消费。
    if (callback == null || !await consumePendingAutoConnect()) return;
    log('收到原生自动连接请求');
    callback();
  }

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
    int attempt = 1,
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
        if (synchronized || !isStillCurrent()) return;
        if (attempt >= _maxDeferredNativeStateRetryAttempts) {
          _failClosedNativeStateReconciliation();
          return;
        }
        _scheduleDeferredNativeStateSync(
          nativeStateEpoch,
          isStillCurrent: isStillCurrent,
          attempt: attempt + 1,
        );
      },
    );
  }

  void _failClosedNativeStateReconciliation() {
    _nativeSessionProtocolAvailable = false;
    _nativeConnectionTransitioning = false;
    _nativeSessionGeneration = null;
    _runningConfigPath = null;
    stopStatusMonitor();
    if (!isRunning && !connectionDesired) return;
    _markNativeConnectionLost();
    const message = '无法确认 Android VPN 运行状态，已标记为断开，请重新连接';
    log(message);
    _notifyNativeRuntimeNotice(const RuntimeNotice.error(message));
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
    return _refreshNativeConnectionState(nativeStateEpoch, source: source);
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
    final underlyingNetworkWasDegraded = _underlyingNetworkAvailable == false ||
        _underlyingNetworkValidated == false;
    final underlyingNetworkRecovered = state.running &&
        underlyingNetworkWasDegraded &&
        state.underlyingNetworkAvailable == true &&
        state.underlyingNetworkValidated == true;
    final underlyingNetworkChanged =
        _underlyingNetworkAvailable != state.underlyingNetworkAvailable ||
            _underlyingNetworkValidated != state.underlyingNetworkValidated;
    _nativeSessionProtocolAvailable = true;
    _nativeConnectionTransitioning = state.transitioning;
    _runningConfigPath = state.protectedConfigPath;
    _nativeSessionGeneration = state.sessionGeneration;
    _underlyingNetworkAvailable = state.underlyingNetworkAvailable;
    _underlyingNetworkValidated = state.underlyingNetworkValidated;

    if (state.running &&
        !connectionDesired &&
        !dartOwnsStart &&
        !dartOwnsStop) {
      // A quick tile or a surviving native session can exist before this Dart
      // process has a connection intent. Adopt it so a later recovery remains
      // cancellable from the application UI.
      requestConnectionIntent(true);
    }
    if (!state.running &&
        !state.transitioning &&
        state.manuallyStopped &&
        !dartOwnsStart &&
        !dartOwnsStop) {
      // Notification and tile actions do not create a Dart stop transaction.
      // Adopt the native user's intent only after that stop has settled.
      requestConnectionIntent(false);
    }
    final terminalUnexpectedStop = !state.running &&
        !state.transitioning &&
        connectionDesired &&
        !dartOwnsStart &&
        !dartOwnsStop &&
        !_intentionalReloadInProgress &&
        (nativeWasRunning || recoveryWasObserved);
    if (state.running) {
      setRunning(true);
      startStatusMonitor();
    } else {
      stopStatusMonitor();
      if (terminalUnexpectedStop) {
        _markNativeConnectionLost();
        _notifyNativeRuntimeNotice(
          const RuntimeNotice.error(
            'VPN 连接已断开\n本地 VPN 服务已停止，尚未确认具体原因。\n'
            '请重新连接；若反复发生，请打开运行日志检查核心状态。',
          ),
        );
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
        (statusChanged ||
            transitionChanged ||
            sessionChanged ||
            underlyingNetworkChanged)) {
      notifyStatusChanged();
    }
    if (underlyingNetworkRecovered) {
      scheduleUserConnectivityObservation(rerunIfActive: true);
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
      log('查询原生 VPN 状态失败: cause=${_safeLogErrorCode(e)}');
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
      log('查询原生 VPN 会话状态失败: cause=${_safeLogErrorCode(e)}');
      return null;
    }
  }

  Future<List<AppDiagnosticCheck>> _androidPlatformDiagnosticChecks() async {
    Object? value;
    try {
      value = await ClashService._channel
          .invokeMethod<Object?>('getNativeDiagnostics')
          .timeout(const Duration(seconds: 3));
    } catch (error) {
      log('查询 Android 原生诊断失败');
    }
    if (value is! Map || value['schemaVersion'] != 1) {
      return const [
        AppDiagnosticCheck(
          id: 'android_native',
          title: 'Android 原生会话',
          status: AppDiagnosticStatus.warning,
          summary: '原生诊断接口不可用或版本不受支持',
          errorCode: AppErrorCode.unknown,
        ),
      ];
    }

    final nativeState = await _parseNativeConnectionState(value);
    final nativeRunning = value['serviceRunning'] == true;
    final transitioning =
        value['operationBusy'] == true || nativeState?.transitioning == true;
    final stateAgrees = nativeState != null &&
        nativeState.running == nativeRunning &&
        nativeRunning == isRunning;
    final checks = <AppDiagnosticCheck>[
      AppDiagnosticCheck(
        id: 'android_native_session',
        title: 'Android 原生会话',
        status: stateAgrees
            ? AppDiagnosticStatus.passed
            : transitioning
                ? AppDiagnosticStatus.warning
                : AppDiagnosticStatus.failed,
        summary: stateAgrees
            ? 'Flutter、VPN 服务与原生会话状态一致'
            : transitioning
                ? '原生连接事务正在切换，稍后可重新诊断'
                : 'Flutter 与原生 VPN 会话状态不一致',
        errorCode:
            stateAgrees || transitioning ? null : AppErrorCode.coreUnavailable,
      ),
    ];

    // The native service owns TUN and Bridge. When Dart is stale, continue
    // diagnosing the authoritative native runtime instead of hiding its
    // component checks behind the Flutter-side state.
    final hasResidualRuntime = value['tunEstablished'] == true ||
        value['bridgeReady'] == true ||
        value['protectMonitorAlive'] == true ||
        nativeState?.protectedConfigPath != null;
    final componentsExplicitlyInactive = value['tunEstablished'] == false &&
        value['bridgeReady'] == false &&
        value['protectMonitorAlive'] == false;
    if (!nativeRunning &&
        !transitioning &&
        !hasResidualRuntime &&
        componentsExplicitlyInactive) {
      checks.addAll(const [
        AppDiagnosticCheck(
          id: 'android_tun',
          title: 'Android TUN',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查 TUN',
        ),
        AppDiagnosticCheck(
          id: 'android_bridge',
          title: 'Android Bridge',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查 Bridge',
        ),
        AppDiagnosticCheck(
          id: 'android_protect',
          title: 'Android 网络保护',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查 socket protect 监控',
        ),
        AppDiagnosticCheck(
          id: 'android_protected_config',
          title: 'Android 受保护配置',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查运行配置所有权',
        ),
      ]);
      return checks;
    }

    void addRuntimeCheck(
      String id,
      String title,
      Object? rawValue,
      String healthySummary,
      String failureSummary,
      String unknownSummary,
      String inactiveSummary,
      String residualSummary,
    ) {
      final status = !nativeRunning
          ? rawValue == true
              ? transitioning
                  ? AppDiagnosticStatus.warning
                  : AppDiagnosticStatus.failed
              : rawValue == false
                  ? AppDiagnosticStatus.skipped
                  : AppDiagnosticStatus.warning
          : rawValue == true
              ? AppDiagnosticStatus.passed
              : rawValue == false
                  ? AppDiagnosticStatus.failed
                  : AppDiagnosticStatus.warning;
      checks.add(
        AppDiagnosticCheck(
          id: id,
          title: title,
          status: status,
          summary: !nativeRunning && rawValue == true
              ? residualSummary
              : !nativeRunning && rawValue == false
                  ? inactiveSummary
                  : status == AppDiagnosticStatus.passed
                      ? healthySummary
                      : status == AppDiagnosticStatus.failed
                          ? failureSummary
                          : unknownSummary,
          errorCode: status == AppDiagnosticStatus.failed
              ? AppErrorCode.coreUnavailable
              : null,
        ),
      );
    }

    addRuntimeCheck(
      'android_tun',
      'Android TUN',
      value['tunEstablished'],
      '已确认当前 Bridge 持有的 TUN 描述符或接口仍存活',
      '未确认当前 Bridge 仍持有存活的 TUN',
      'TUN 所有权探针暂时不可用',
      '当前未连接，TUN 已停止',
      '原生服务已停止，但同一会话的 TUN 接口仍存活',
    );
    addRuntimeCheck(
      'android_bridge',
      'Android Bridge',
      value['bridgeReady'],
      'Bridge 原生运行探针已确认；API 由共享健康检查独立验证',
      'Bridge 原生运行探针确认核心未运行',
      'Bridge 原生运行探针超时或正在执行',
      '当前未连接，Bridge 已停止',
      '原生服务已停止，但 Bridge 仍报告运行',
    );
    addRuntimeCheck(
      'android_protect',
      'Android 网络保护',
      value['protectMonitorAlive'],
      'socket protect 监控线程存活',
      'socket protect 监控线程未运行',
      'socket protect 监控状态暂时不可用',
      '当前未连接，socket protect 监控已停止',
      '原生服务已停止，但 socket protect 监控仍存活',
    );
    final protectedConfigAvailable = nativeState?.protectedConfigPath != null &&
        nativeState?.sessionGeneration != null;
    checks.add(
      AppDiagnosticCheck(
        id: 'android_protected_config',
        title: 'Android 受保护配置',
        status: protectedConfigAvailable
            ? AppDiagnosticStatus.passed
            : AppDiagnosticStatus.failed,
        summary:
            protectedConfigAvailable ? '当前原生会话持有可信配置快照' : '当前原生会话缺少可信配置快照或代际',
        errorCode: protectedConfigAvailable ? null : AppErrorCode.configInvalid,
      ),
    );
    return checks;
  }

  Future<_NativeConnectionState?> _parseNativeConnectionState(
    Object? value,
  ) async {
    if (value is! Map) return null;
    final rawRunning = value['running'];
    final rawTransitioning = value['transitioning'];
    if (rawRunning is! bool || rawTransitioning is! bool) {
      log('原生 VPN 返回了缺少明确布尔状态的会话快照');
      return null;
    }
    final running = rawRunning;
    final transitioning = rawTransitioning;
    final rawManuallyStopped = value['manuallyStopped'];
    if (rawManuallyStopped != null && rawManuallyStopped is! bool) {
      log('原生 VPN 返回了无效的手动停止状态');
      return null;
    }
    final manuallyStopped = rawManuallyStopped == true;
    if (running && manuallyStopped) {
      log('原生 VPN 的运行状态与手动停止状态不一致');
      return null;
    }
    final rawSessionGeneration = value['sessionGeneration'];
    if (rawSessionGeneration != null &&
        (rawSessionGeneration is! int || rawSessionGeneration <= 0)) {
      log('原生 VPN 返回了无效的会话代际');
      return null;
    }
    final sessionGeneration = rawSessionGeneration as int?;
    if (running != (sessionGeneration != null)) {
      log('原生 VPN 的运行状态与会话代际不一致');
      return null;
    }
    final rawUnderlyingAvailable = value['underlyingNetworkAvailable'];
    final rawUnderlyingValidated = value['underlyingNetworkValidated'];
    if ((rawUnderlyingAvailable != null && rawUnderlyingAvailable is! bool) ||
        (rawUnderlyingValidated != null && rawUnderlyingValidated is! bool)) {
      log('原生 VPN 返回了无效的底层网络状态');
      return null;
    }
    final underlyingNetworkAvailable = rawUnderlyingAvailable as bool?;
    final underlyingNetworkValidated = rawUnderlyingValidated as bool?;
    if (underlyingNetworkAvailable == false &&
        underlyingNetworkValidated == true) {
      log('原生 VPN 返回了矛盾的底层网络状态');
      return null;
    }
    final rawPathValue = value['protectedConfigPath'];
    if (rawPathValue != null && rawPathValue is! String) {
      log('原生 VPN 返回了无效的受保护配置路径类型');
      return null;
    }
    final rawPathTrusted = value['protectedConfigTrusted'];
    if (rawPathTrusted != null && rawPathTrusted is! bool) {
      log('原生 VPN 返回了无效的受保护配置证明');
      return null;
    }
    final rawPath = rawPathValue as String?;
    if (rawPath == null || rawPath.isEmpty) {
      return (
        running: running,
        transitioning: transitioning,
        manuallyStopped: manuallyStopped,
        protectedConfigPath: null,
        sessionGeneration: sessionGeneration,
        underlyingNetworkAvailable: underlyingNetworkAvailable,
        underlyingNetworkValidated: underlyingNetworkValidated,
      );
    }
    final file = File(rawPath).absolute;
    final name = file.uri.pathSegments.last;
    final supportedName = name == 'config.yaml' ||
        (name.startsWith('config-') && name.endsWith('.yaml'));
    if (!supportedName ||
        (rawPathTrusted != true &&
            (file.parent.path != Directory(configDir).absolute.path ||
                await FileSystemEntity.type(file.path, followLinks: false) !=
                    FileSystemEntityType.file))) {
      log('原生 VPN 返回了无效的受保护配置路径');
      return (
        running: running,
        transitioning: transitioning,
        manuallyStopped: manuallyStopped,
        protectedConfigPath: null,
        sessionGeneration: sessionGeneration,
        underlyingNetworkAvailable: underlyingNetworkAvailable,
        underlyingNetworkValidated: underlyingNetworkValidated,
      );
    }
    return (
      running: running,
      transitioning: transitioning,
      manuallyStopped: manuallyStopped,
      protectedConfigPath: file.path,
      sessionGeneration: sessionGeneration,
      underlyingNetworkAvailable: underlyingNetworkAvailable,
      underlyingNetworkValidated: underlyingNetworkValidated,
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
      log('原生库目录查询失败: cause=${_safeLogErrorCode(e)}');
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
