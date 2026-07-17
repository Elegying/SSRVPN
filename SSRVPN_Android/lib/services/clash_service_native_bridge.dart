part of 'clash_service.dart';

typedef _NativeConnectionState = ({
  bool running,
  bool transitioning,
  String? protectedConfigPath,
  int? sessionGeneration,
});

extension AndroidNativeBridge on ClashService {
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
    final connected = call.arguments == true;
    final nativeStateEpoch = ++_nativeStateEpoch;
    if (!connected) _nativeSessionGeneration = null;
    unawaited(_restoreNativeConnectionState(nativeStateEpoch));
    if (isRunning == connected) return;
    setRunning(connected);
    log(connected ? '原生通知: VPN 已连接' : '原生通知: VPN 已断开');
    if (connected) {
      startStatusMonitor();
    } else {
      stopStatusMonitor();
    }
    notifyStatusChanged();
  }

  Future<void> _syncNativeState() async {
    final nativeStateEpoch = _nativeStateEpoch;
    final state = await _queryNativeConnectionState();
    if (nativeStateEpoch != _nativeStateEpoch || state == null) return;
    _nativeSessionProtocolAvailable = true;
    _runningConfigPath = state.protectedConfigPath;
    _nativeSessionGeneration = state.sessionGeneration;
    if (state.running && !isRunning) {
      setRunning(true);
      log('检测到 VPN 已在运行（磁贴启动），同步状态');
      startStatusMonitor();
    }
  }

  Future<void> _restoreNativeConnectionState(int nativeStateEpoch) async {
    final state = await _queryNativeConnectionState();
    if (state != null && nativeStateEpoch == _nativeStateEpoch) {
      _nativeSessionProtocolAvailable = true;
      _runningConfigPath = state.protectedConfigPath;
      _nativeSessionGeneration = state.sessionGeneration;
    }
  }

  Future<bool> _ensureNativeSessionForMutation() async {
    if (_nativeSessionProtocolAvailable) {
      return isRunning && _nativeSessionGeneration != null;
    }
    final state = await _queryNativeConnectionState();
    if (state == null || !state.running || state.sessionGeneration == null) {
      return false;
    }
    _nativeSessionProtocolAvailable = true;
    _runningConfigPath = state.protectedConfigPath;
    _nativeSessionGeneration = state.sessionGeneration;
    return true;
  }

  Future<bool> _isNativeSessionCurrent(int expectedGeneration) async {
    final state = await _queryNativeConnectionState();
    if (state?.running == true &&
        state?.sessionGeneration == expectedGeneration) {
      _runningConfigPath = state?.protectedConfigPath;
      return true;
    }
    if (state != null) {
      final statusChanged = isRunning != state.running;
      final sessionChanged =
          _nativeSessionGeneration != state.sessionGeneration;
      _nativeSessionProtocolAvailable = true;
      _runningConfigPath = state.protectedConfigPath;
      _nativeSessionGeneration = state.sessionGeneration;
      if (statusChanged) {
        setRunning(state.running);
        if (state.running) {
          startStatusMonitor();
        } else {
          stopStatusMonitor();
        }
      }
      if (statusChanged || sessionChanged) notifyStatusChanged();
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
