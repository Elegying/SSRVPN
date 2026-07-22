part of 'clash_service.dart';

class _DesktopStartCancelled implements Exception {}

class MacosNativeCoreHandle {
  const MacosNativeCoreHandle({
    required this.pid,
    required this.pidRecordContents,
  });

  final int pid;
  final String pidRecordContents;
}

class MacosNativeCoreStatus {
  const MacosNativeCoreStatus({
    required this.isRunning,
    required this.exitCode,
    required this.standardOutput,
    required this.standardError,
  });

  final bool isRunning;
  final int? exitCode;
  final String standardOutput;
  final String standardError;
}

MacosNativeCoreHandle parseMacosNativeCoreLaunch(Object? value) {
  if (value is! Map) throw StateError('原生核心启动结果无效');
  final rawPid = value['pid'];
  final corePid = rawPid is int ? rawPid : null;
  final record = value['pidRecordContents'];
  if (corePid == null || record is! String) {
    throw StateError('原生核心启动结果无效');
  }
  return MacosNativeCoreHandle(
    pid: corePid,
    pidRecordContents: validateMacosCorePidRecord(record, corePid),
  );
}

MacosNativeCoreStatus parseMacosNativeCoreStatus(Object? value) {
  if (value is! Map ||
      value['isRunning'] is! bool ||
      value['standardOutput'] is! String ||
      value['standardError'] is! String) {
    throw StateError('原生核心状态无效');
  }
  final isRunning = value['isRunning'] as bool;
  final rawExitCode = value['exitCode'];
  final expectedKeys = isRunning
      ? const {'isRunning', 'standardOutput', 'standardError'}
      : const {'isRunning', 'exitCode', 'standardOutput', 'standardError'};
  if (value.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(value.keys.toSet()).isNotEmpty ||
      (isRunning ? rawExitCode != null : rawExitCode is! int)) {
    throw StateError('原生核心退出码无效');
  }
  return MacosNativeCoreStatus(
    isRunning: isRunning,
    exitCode: rawExitCode as int?,
    standardOutput: value['standardOutput'] as String,
    standardError: value['standardError'] as String,
  );
}

String validateMacosCorePidRecord(String? contents, int expectedPid) {
  if (contents == null || !contents.endsWith('\n')) {
    throw StateError('原生进程身份记录无效');
  }
  final fields = contents.substring(0, contents.length - 1).split(' ');
  final recordedPid = fields.length == 4 ? int.tryParse(fields[1]) : null;
  final startSeconds = fields.length == 4 ? int.tryParse(fields[2]) : null;
  final startMicroseconds = fields.length == 4 ? int.tryParse(fields[3]) : null;
  final canonical = fields.length == 4 &&
      fields[0] == 'v2' &&
      recordedPid == expectedPid &&
      expectedPid > 1 &&
      startSeconds != null &&
      startSeconds > 0 &&
      startMicroseconds != null &&
      startMicroseconds >= 0 &&
      startMicroseconds < 1000000 &&
      contents == 'v2 $recordedPid $startSeconds $startMicroseconds\n';
  if (!canonical) throw StateError('原生进程身份记录无效');
  return contents;
}

String buildMacosUnexpectedExitNotice({
  required int exitCode,
  required bool proxyRecovered,
}) =>
    proxyRecovered
        ? 'Mihomo 异常退出（退出码 $exitCode），系统代理已恢复。请点击首页“连接”重试。'
        : 'Mihomo 异常退出（退出码 $exitCode），系统代理恢复失败。已保留恢复记录并暂停新连接，请点击首页“连接”重试；仍失败请打开日志诊断。';

String? buildMacosStartupRecoveryNotice({
  required bool proxyRecoveryPending,
  required bool corePreparationPending,
}) {
  if (proxyRecoveryPending) {
    return '检测到上次退出遗留的系统代理状态。为保护网络，SSRVPN 已保留旧核心并暂停新连接；请点击首页“连接”重试恢复。';
  }
  if (corePreparationPending) {
    return '系统代理已恢复，但 Mihomo 核心安全准备尚未完成。SSRVPN 已保留旧核心并暂停新连接；请点击首页“连接”重试准备。';
  }
  return null;
}

mixin _MacosCoreLifecycle on ClashServiceBase {
  static const _filePath = '/usr/bin/file';
  static const _coreProcessChannel = MethodChannel('ssrvpn/core_process');

  MacosNativeCoreHandle? _clashProcess;
  MacosTunSession? _tunSession;
  bool _stoppingCore = false;
  Future<bool>? _startOperation;
  Completer<void>? _startCancellation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;
  Future<void>? _nativeCoreStatusWatcher;
  int _nativeCoreStatusWatchGeneration = 0;
  int _startGeneration = 0;
  String _corePath = '';
  String? _corePidRecordContents;
  String? _startupDisabledReason;
  late final SystemProxyService _proxyService;
  bool _coreAssetsPrepared = false;
  bool _startupBlockedByProxyRecovery = false;
  bool _startupBlockedByTunDnsRecovery = false;
  bool _runCoreProbesAfterRecovery = true;
  Future<bool>? _proxyRecoveryOperation;
  final CoreRecoveryPolicy _automaticRecoveryPolicy =
      CoreRecoveryPolicy(maxAttempts: 1);
  String? _lastUnexpectedExitNotice;
  DateTime? _lastTunDataPathProbeAt;
  bool _lastTunDataPathHealthy = true;
  Future<bool>? _tunDataPathProbe;
  int _tunDataPathProbeGeneration = 0;
  int _consecutiveTunDataPathFailures = 0;

  @protected
  Duration get tunDataPathProbeInterval => const Duration(seconds: 30);

  @protected
  int get tunDataPathFailureThreshold => 2;

  bool get isStartupDisabled => _startupDisabledReason != null;
  String? get startupDisabledReason => _startupDisabledReason;
  String get corePath => _corePath;
  bool get coreExists => File(_corePath).existsSync();
  bool get hasPendingSystemProxyRecovery =>
      _proxyService.recoveryPending || _startupBlockedByProxyRecovery;
  String? get startupRecoveryNotice => buildMacosStartupRecoveryNotice(
        proxyRecoveryPending: _proxyService.recoveryPending,
        corePreparationPending: _startupBlockedByProxyRecovery,
      );
  String? get lastUnexpectedExitNotice => _lastUnexpectedExitNotice;
  String get _recoveryDiagnosticSummary {
    if (_proxyService.recoveryPending) {
      return '检测到 SSRVPN 自有的待恢复代理状态';
    }
    if (_startupBlockedByProxyRecovery) {
      return '系统代理已恢复，但 Mihomo 核心资产尚未安全就绪';
    }
    return '没有待恢复的 SSRVPN 系统代理状态';
  }

  @override
  Future<bool> diagnosticCoreAvailable() async =>
      _corePath.isNotEmpty && await _isRegularUnprivilegedCoreFile();

  Future<bool> _isRegularUnprivilegedCoreFile() async {
    try {
      final type = await FileSystemEntity.type(_corePath, followLinks: false);
      if (type != FileSystemEntityType.file) return false;
      final stat = await File(_corePath).stat();
      return stat.type == FileSystemEntityType.file &&
          (stat.mode & ClashService._privilegedModeBits) == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [
        AppDiagnosticCheck(
          id: 'system_proxy',
          title: '系统代理恢复',
          status: hasPendingSystemProxyRecovery
              ? AppDiagnosticStatus.warning
              : AppDiagnosticStatus.passed,
          summary: _recoveryDiagnosticSummary,
          errorCode: hasPendingSystemProxyRecovery
              ? AppErrorCode.proxyRecoveryPending
              : null,
          repairAction: hasPendingSystemProxyRecovery
              ? AppRepairAction.retryOwnedProxyRecovery
              : null,
        ),
      ];

  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async {
    if (action != AppRepairAction.retryOwnedProxyRecovery) {
      return super.repairDiagnosticIssue(action);
    }
    if (isRunning) {
      return const AppRepairResult(
        success: false,
        message: '请先断开连接，再修复 SSRVPN 自有的系统代理状态。',
      );
    }
    final recovered = await recoverPendingSystemProxy();
    return AppRepairResult(
      success: recovered,
      message: recovered ? 'SSRVPN 自有的系统代理状态已恢复。' : '系统代理恢复未完成，请复制诊断报告后重试。',
    );
  }

  Future<bool> recoverPendingSystemProxy() async {
    final current = _proxyRecoveryOperation;
    if (current != null) return current;
    final operation = _recoverPendingSystemProxyInternal();
    _proxyRecoveryOperation = operation;
    operation.whenComplete(() {
      if (identical(_proxyRecoveryOperation, operation)) {
        _proxyRecoveryOperation = null;
      }
    });
    return operation;
  }

  Future<bool> _recoverPendingSystemProxyInternal() async {
    if (!hasPendingSystemProxyRecovery) return true;
    if (_proxyService.recoveryPending) {
      log('检测到上次异常退出留下的系统代理状态，正在重试恢复...');
      final recovered = await _proxyService.clearSystemProxy();
      if (!recovered) {
        final reason = _proxyService.lastError ?? '系统代理旧状态恢复失败';
        setLastStartError(reason);
        log('❌ $reason');
        notifyStatusChanged();
        return false;
      }
    }

    try {
      await _prepareCoreAssetsAfterProxyRecovery(
        runVersionProbe: _runCoreProbesAfterRecovery,
      );
      _startupBlockedByProxyRecovery = false;
      _startupDisabledReason = null;
      setLastStartError(null);
      log('✅ 旧系统代理状态已恢复，核心资产已安全就绪');
      notifyStatusChanged();
      return true;
    } catch (error) {
      _startupBlockedByProxyRecovery = true;
      final reason = '系统代理已恢复，但 Mihomo 核心安全准备失败: $error';
      disableStartup(reason);
      notifyStatusChanged();
      return false;
    }
  }

  @protected
  Future<bool> checkMihomoApiHealth() => super.healthCheck();

  @protected
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() =>
      _proxyService.currentSystemProxyOwnershipStatus();

  @protected
  bool get systemProxyOwnershipChangedSinceLastAcquisition =>
      _proxyService.ownershipChangedSinceLastAcquisition;

  Future<bool> _verifyTunRuntimeConfig() async {
    final tun = (await getConfigs())?['tun'];
    if (tun is Map && tun['enable'] == true) return true;
    setLastHealthCheckError(
      'TUN_CONFIG_MISMATCH: Mihomo API 已就绪，但 TUN listener 未启用',
    );
    return false;
  }

  @override
  Future<bool> healthCheck() async {
    if (!await checkMihomoApiHealth()) {
      final detail = lastHealthCheckError ?? 'Mihomo API 不可用';
      setLastHealthCheckError('CORE_API_UNAVAILABLE: $detail');
      return false;
    }
    if (!settings.enableTun) {
      if (isRunning) {
        final ownershipStatus = await inspectSystemProxyOwnership();
        if (ownershipStatus == SystemProxyOwnershipStatus.owned) {
          setLastHealthCheckError(null);
          return true;
        }
        final ownershipError = _proxyService.lastError ?? 'macOS 系统代理所有权无法确认';
        final prefix =
            ownershipStatus == SystemProxyOwnershipStatus.externallyChanged
                ? desktopSystemProxyOwnershipLostPrefix
                : desktopSystemProxyOwnershipUnavailablePrefix;
        setLastHealthCheckError(
          '$prefix $ownershipError',
        );
        return false;
      }
      setLastHealthCheckError(null);
      return true;
    }
    if (!await _verifyTunRuntimeConfig()) return false;
    if (!isRunning) return true;

    final tunSession = _tunSession;
    if (tunSession == null) {
      setLastHealthCheckError('TUN_SERVICE_LOST: TUN 授权会话不存在');
      return false;
    }
    final runnerState = await tunSession.startupState();
    if (runnerState != MacosTunStartupState.running) {
      setLastHealthCheckError(
        'TUN_SERVICE_LOST: ${runnerState == MacosTunStartupState.failed ? (tunSession.lastError ?? 'TUN 授权会话已失败') : 'TUN 授权会话已停止响应'}',
      );
      return false;
    }
    setLastHealthCheckError(null);
    return true;
  }

  @override
  @protected
  Future<void> observeDataPlaneHealth() async {
    if (!isRunning || !settings.enableTun) return;
    await _checkThrottledTunDataPath();
  }

  Future<bool> _checkThrottledTunDataPath() async {
    final activeProbe = _tunDataPathProbe;
    if (activeProbe != null) return activeProbe;

    final now = DateTime.now();
    final lastProbeAt = _lastTunDataPathProbeAt;
    if (lastProbeAt != null &&
        now.difference(lastProbeAt) < tunDataPathProbeInterval) {
      return _lastTunDataPathHealthy;
    }

    final probeGeneration = _tunDataPathProbeGeneration;
    final probe = _probeTunDataPath(probeGeneration);
    _tunDataPathProbe = probe;
    try {
      return await probe;
    } finally {
      if (identical(_tunDataPathProbe, probe)) _tunDataPathProbe = null;
    }
  }

  Future<bool> _probeTunDataPath(int probeGeneration) async {
    final warning = await verifyUserConnectivity(
      maxAttempts: 2,
      retryDelay: const Duration(seconds: 1),
      shouldContinue: () => isRunning && settings.enableTun,
    );
    if (probeGeneration != _tunDataPathProbeGeneration) return true;
    if (!isRunning || !settings.enableTun) return false;
    _lastTunDataPathProbeAt = DateTime.now();
    _lastTunDataPathHealthy = warning == null;
    if (warning != null) {
      _consecutiveTunDataPathFailures++;
      setConnectivityWarning(
        '节点或外部网络暂时不可用，TUN 保持连接并继续恢复：$warning',
      );
      log(
        'EXTERNAL_CHECK_BLOCKED '
        '($_consecutiveTunDataPathFailures/$tunDataPathFailureThreshold): '
        '$warning',
      );
      if (_consecutiveTunDataPathFailures >= tunDataPathFailureThreshold) {
        await _attemptTunNodeRecovery(probeGeneration);
      }
    } else {
      if (_consecutiveTunDataPathFailures > 0) {
        log('TUN 数据通道已恢复，核心和 TUN 会话始终保持运行');
      }
      _consecutiveTunDataPathFailures = 0;
      setConnectivityWarning(null);
    }
    return _lastTunDataPathHealthy;
  }

  Future<void> _attemptTunNodeRecovery(int probeGeneration) async {
    if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
    final groups = await getProxies();
    ProxyGroup? proxyGroup;
    for (final group in groups) {
      if (group.name == 'PROXY') {
        proxyGroup = group;
        break;
      }
    }
    if (proxyGroup == null || proxyGroup.nodes.length < 2) {
      log('NODE_RECOVERY_UNAVAILABLE: 没有其他可切换节点，TUN 保持受限连接');
      return;
    }
    final original = await currentSelectedProxyName();
    if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
    if (original == null) {
      setConnectivityWarning(
        '无法确认当前节点，未执行自动切换；TUN 仍保持接管，请手动选择节点',
      );
      log('NODE_RECOVERY_UNAVAILABLE: 无法确认当前节点，未执行自动切换');
      return;
    }
    final candidates = proxyGroup.nodes
        .where((node) => node.name != original)
        .take(3)
        .toList(growable: false);
    var recoveryOwnedSelection = original;
    setConnectivityWarning('当前节点不可用，TUN 保持接管并正在热切换节点…');
    for (final candidate in candidates) {
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      final selectedBeforeSwitch = await currentSelectedProxyName();
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      if (selectedBeforeSwitch != recoveryOwnedSelection) {
        _handleExternalNodeSelectionDuringRecovery();
        return;
      }
      final switched = await switchSelectedProxy(candidate.name);
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      if (!switched) continue;
      recoveryOwnedSelection = candidate.name;
      final warning = await verifyUserConnectivity(
        maxAttempts: 2,
        retryDelay: const Duration(seconds: 1),
        shouldContinue: () =>
            probeGeneration == _tunDataPathProbeGeneration && isRunning,
      );
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      final selectedAfterProbe = await currentSelectedProxyName();
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      if (selectedAfterProbe != recoveryOwnedSelection) {
        _handleExternalNodeSelectionDuringRecovery();
        return;
      }
      if (warning == null) {
        _lastTunDataPathHealthy = true;
        _consecutiveTunDataPathFailures = 0;
        setConnectivityWarning(null);
        log('NODE_RECOVERED: 已热切换到 ${candidate.name}，TUN 会话未重建');
        notifyStatusChanged();
        return;
      }
      log('NODE_RECOVERY_FAILED: ${candidate.name}: $warning');
    }
    if (probeGeneration == _tunDataPathProbeGeneration && isRunning) {
      final selectedBeforeRestore = await currentSelectedProxyName();
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      if (selectedBeforeRestore != recoveryOwnedSelection) {
        _handleExternalNodeSelectionDuringRecovery();
        return;
      }
      final restored = await switchSelectedProxy(original);
      if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
      if (!restored) {
        setConnectivityWarning(
          '节点自动恢复未成功，且未能恢复原节点；TUN 仍保持接管，请手动选择节点',
        );
        log('NODE_ROLLBACK_FAILED: 自动恢复失败后未能恢复原节点 $original');
        return;
      }
    }
    if (probeGeneration != _tunDataPathProbeGeneration || !isRunning) return;
    setConnectivityWarning('节点自动恢复未成功，TUN 仍保持接管；请手动切换节点或刷新订阅');
  }

  void _handleExternalNodeSelectionDuringRecovery() {
    _lastTunDataPathProbeAt = null;
    _consecutiveTunDataPathFailures = 0;
    setConnectivityWarning('节点已切换，TUN 保持连接并等待重新验证…');
    log('NODE_RECOVERY_CANCELLED: 检测到其他节点选择，未覆盖当前选择');
  }

  Future<bool> _verifyTunFinalControlPlaneHealth(
    MacosTunSession tunSession,
  ) async {
    if (!await checkMihomoApiHealth()) return false;
    if (!await _verifyTunRuntimeConfig()) return false;
    final runnerState = await tunSession.startupState();
    if (runnerState == MacosTunStartupState.running) return true;
    setLastHealthCheckError(
      runnerState == MacosTunStartupState.failed
          ? (tunSession.lastError ?? 'TUN 授权会话已失败')
          : 'TUN 授权会话尚未完成网络接管',
    );
    return false;
  }

  Future<void> _verifyCoreForExecution();
  Future<void> _prepareCoreAssetsAfterProxyRecovery({
    required bool runVersionProbe,
  });

  @override
  Future<void> onStopRequired() => stop();

  @override
  Future<bool> recoverAfterHealthCheckFailure(
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
    if (!settings.enableTun) {
      // The API and the system proxy can fail at the same time. healthCheck()
      // returns as soon as the API is unavailable, so inspect ownership again
      // immediately before any stop/restart that could reacquire the proxy.
      final ownershipStatus = await inspectSystemProxyOwnership();
      if (ownershipStatus != SystemProxyOwnershipStatus.owned) {
        final externallyChanged =
            ownershipStatus == SystemProxyOwnershipStatus.externallyChanged;
        // Invalidate intent before asynchronous cleanup so neither the health
        // monitor nor an in-flight recovery can reacquire the system proxy.
        markConnectionLost();
        try {
          await stop();
        } catch (error) {
          log('系统代理所有权失效后的核心清理未完成: $error');
          notifyRuntimeNotice(
            '已取消自动重连，但系统代理或 Mihomo 核心清理状态无法确认；'
            '请在诊断页检查并重试断开，SSRVPN 不会重新接管代理。',
          );
          return false;
        }
        notifyRuntimeNotice(
          externallyChanged
              ? '检测到系统代理已被其他程序接管，SSRVPN 已安全断开且不会覆盖当前代理。'
              : '无法确认当前系统代理所有权，SSRVPN 已安全断开且不会覆盖未知代理状态。',
        );
        return false;
      }
    }
    if (!_automaticRecoveryPolicy.tryAcquire()) {
      await stop();
      return false;
    }

    notifyRuntimeNotice('Mihomo 持续失去响应，正在执行一次安全重启…');
    try {
      await stop();
    } catch (error) {
      log('健康检查恢复时停止 Mihomo 失败: $error');
      return false;
    }
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      return false;
    }
    if (!settings.enableTun &&
        systemProxyOwnershipChangedSinceLastAcquisition) {
      markConnectionLost();
      notifyRuntimeNotice(
        '系统代理在清理期间发生变化，已取消自动重连；'
        'SSRVPN 不会重新接管当前代理。',
      );
      return false;
    }
    return recoverDesktopConnection(connectionGeneration);
  }

  void disableStartup(String reason) {
    _startupDisabledReason = reason;
    setLastStartError(reason);
    log(reason);
  }

  Future<void> _logCoreVersion() async {
    await _verifyCoreForExecution();
    try {
      final stat = await File(_corePath).stat();
      log(
        '核心文件大小: ${(stat.size / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } catch (_) {}

    try {
      final fileInfo = await _runProcess(
        _filePath,
        [_corePath],
        timeout: const Duration(seconds: 5),
      );
      if (fileInfo.exitCode == 0 &&
          fileInfo.stdout.toString().trim().isNotEmpty) {
        log('核心架构: ${fileInfo.stdout.toString().trim()}');
      }
    } catch (_) {}

    try {
      await _verifyCoreForExecution();
      final result = await _runProcess(
        _corePath,
        ['-v'],
        workingDirectory: configDir,
        timeout: const Duration(seconds: 5),
      );
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode == 0 && output.isNotEmpty) {
        log('核心版本: ${output.replaceAll(RegExp(r'\s+'), ' ')}');
      } else if (result.exitCode == 124) {
        log('核心版本检查超时');
      } else {
        log('核心版本检查失败，退出码: ${result.exitCode}');
      }
    } catch (e) {
      log('核心无法执行: $e');
    }
  }

  Future<void> _terminateOrphanedCores() async {
    if (_proxyService.recoveryPending) {
      throw StateError('系统代理恢复完成前不得终止遗留 Mihomo 核心');
    }
    if (_corePath.isEmpty || !Platform.isMacOS) return;
    final pidFile = File(
      '$configDir${Platform.pathSeparator}AtlasCore.pid',
    );
    if (await FileSystemEntity.type(pidFile.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    try {
      final terminated = await _coreProcessChannel.invokeMethod<bool>(
        'terminateOwnedCore',
        {'directory': configDir},
      );
      if (terminated != true) {
        throw StateError('遗留核心身份或退出状态无法安全确认');
      }
      _corePidRecordContents = null;
      log('已清理遗留的 Mihomo 进程');
    } catch (e) {
      throw StateError('无法安全确认并清理遗留核心: $e');
    }
  }

  void setCorePath(String path) {
    _corePath = path;
  }

  @override
  Future<bool> start() => _start();

  @override
  Future<bool> startForAutomaticRecovery() => _start(automaticRecovery: true);

  Future<bool> _start({bool automaticRecovery = false}) {
    if (!automaticRecovery) _automaticRecoveryPolicy.reset();
    final current = _startOperation;
    if (current != null) return current;

    final startToken = ++_startGeneration;
    _startCancellation = Completer<void>();
    final operation = _startInternal(startToken);
    _startOperation = operation;
    operation.then<void>(
      (_) => _clearStartOperation(operation),
      onError: (_, __) => _clearStartOperation(operation),
    );
    return operation;
  }

  Future<bool> _startInternal(int startToken) async {
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    _ensureStartCurrent(startToken);
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
    _ensureStartCurrent(startToken);
    setLastStartError(null);

    try {
      if (_startupBlockedByTunDnsRecovery &&
          !await _recoverPendingTunDnsInternal(startToken)) {
        return false;
      }
    } on _DesktopStartCancelled {
      setLastStartError('连接已取消');
      log('TUN DNS 恢复重试已取消');
      return false;
    } catch (error, stack) {
      const reason = 'TUN DNS 恢复重试失败，已暂停新连接；请再次点击连接重试';
      disableStartup(reason);
      log('TUN DNS 恢复重试异常: $error');
      log('堆栈: $stack');
      notifyStatusChanged();
      return false;
    }
    if (_startupDisabledReason != null) {
      setLastStartError(_startupDisabledReason);
      log(_startupDisabledReason!);
      return false;
    }
    if (_corePath.isEmpty || configDir.isEmpty || configPath.isEmpty) {
      setLastStartError('Mihomo service is not initialized');
      log(lastStartError!);
      return false;
    }
    if (!_coreAssetsPrepared) {
      setLastStartError('Mihomo 核心资产尚未通过安全准备，已拒绝启动');
      log(lastStartError!);
      return false;
    }

    if (isRunning || _clashProcess != null) {
      if (isRunning) {
        try {
          if (await healthCheck()) return true;
        } catch (_) {}
      }
      _ensureStartCurrent(startToken);
      final stoppedSafely = await _stopInternal();
      _ensureStartCurrent(startToken);
      if (!stoppedSafely || _clashProcess != null) {
        setLastStartError(
          lastStartError ?? '现有 Mihomo 核心无法安全停止，已拒绝启动新的核心',
        );
        log('❌ $lastStartError');
        return false;
      }
    }

    try {
      final startupWatch = Stopwatch()..start();
      log('启动 Mihomo 核心...');
      log('核心路径: $_corePath');
      log('配置目录: $configDir');

      if (!File(_corePath).existsSync()) {
        setLastStartError('找不到核心文件，应用资源可能未完整安装');
        log('错误: 找不到核心文件 $_corePath');
        return false;
      }
      if (!File(configPath).existsSync()) {
        setLastStartError('找不到生成的 Mihomo 配置文件');
        log('错误: 找不到配置文件 $configPath');
        return false;
      }

      final tmpDir = '$configDir${Platform.pathSeparator}tmp';
      await Directory(tmpDir).create(recursive: true);
      _ensureStartCurrent(startToken);
      final environment = {
        'TMPDIR': tmpDir,
        'TMP': tmpDir,
        'TEMP': tmpDir,
      };

      await _terminateOrphanedCores();
      _ensureStartCurrent(startToken);
      if (!await _validateConfig(environment)) {
        setLastStartError(
          lastStartError ?? 'Mihomo 配置校验失败，请打开运行日志查看具体错误',
        );
        return false;
      }
      _ensureStartCurrent(startToken);

      if (settings.enableTun) {
        return await _startTunCore(startToken, startupWatch);
      }

      await _verifyCoreForExecution();
      _ensureStartCurrent(startToken);

      final processStartWatch = Stopwatch()..start();
      final startedProcess = parseMacosNativeCoreLaunch(
        await _coreProcessChannel.invokeMethod<Object?>(
          'launchOwnedCore',
          {'directory': configDir},
        ),
      );
      log(
        'Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms',
      );
      _clashProcess = startedProcess;
      final pidRecordContents = startedProcess.pidRecordContents;
      _corePidRecordContents = pidRecordContents;
      _ensureStartCurrent(startToken);
      int? startupExitCode;
      final startupOutput = <String>[];

      var healthy = false;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && startupExitCode == null) {
        _ensureStartCurrent(startToken);
        final nativeStatus = await _readNativeCoreStatus(startedProcess);
        _recordNativeCoreDiagnostics(nativeStatus, startupOutput);
        if (!nativeStatus.isRunning) {
          startupExitCode = nativeStatus.exitCode ?? -1;
          break;
        }
        healthy = await healthCheck();
        _ensureStartCurrent(startToken);
        if (healthy) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }

      if (healthy) {
        _ensureStartCurrent(startToken);
        final proxySet = await _proxyService.setSystemProxy(
          '127.0.0.1',
          settings.proxyPort,
        );
        if (!proxySet) {
          setLastStartError(
            _proxyService.lastError ?? 'macOS 系统代理设置失败',
          );
          log(lastStartError!);
          await _stopInternal();
          return false;
        }
        _ensureStartCurrent(startToken);
        log('macOS 系统代理已设置');

        final processStillHealthy = await healthCheck();
        _ensureStartCurrent(startToken);
        final nativeStatus = await _readNativeCoreStatus(startedProcess);
        _recordNativeCoreDiagnostics(nativeStatus, startupOutput);
        if (!nativeStatus.isRunning) {
          startupExitCode = nativeStatus.exitCode ?? -1;
        }
        final canCommitRunning = identical(_clashProcess, startedProcess) &&
            startupExitCode == null &&
            nativeStatus.isRunning &&
            processStillHealthy;
        if (!canCommitRunning) {
          setLastStartError(
            startupExitCode == null
                ? 'Mihomo 在系统代理设置期间失去响应'
                : 'Mihomo 在系统代理设置期间退出（退出码 $startupExitCode）',
          );
          log(lastStartError!);
          await _stopInternal();
          return false;
        }

        setRunning(true);
        resetHealthCheckFailures();
        log(
          'Mihomo API 就绪，耗时 ${startupWatch.elapsedMilliseconds}ms',
        );

        notifyStatusChanged();
        startStatusMonitor();
        _scheduleNativeCoreStatusWatch(startedProcess);
        return true;
      }

      if (startupExitCode != null) {
        final detail = startupOutput.isEmpty ? '' : ': ${startupOutput.last}';
        setLastStartError(
          'Mihomo 提前退出（退出码 $startupExitCode）$detail',
        );
      } else {
        setLastStartError('电脑性能不足或核心启动过慢，请重新连接');
      }
      log('核心启动失败: $lastStartError');
      await _stopInternal();
      return false;
    } on _DesktopStartCancelled {
      final tunStopError = _startupBlockedByTunDnsRecovery
          ? StateError(_startupDisabledReason ?? 'TUN DNS 恢复失败')
          : null;
      setLastStartError(
        tunStopError == null
            ? '连接已取消'
            : (_startupDisabledReason ?? 'TUN DNS 恢复失败'),
      );
      log('Mihomo 启动已取消');
      await _stopInternal(priorTunStopError: tunStopError);
      return false;
    } catch (e, stack) {
      final tunStopError = _startupBlockedByTunDnsRecovery ? e : null;
      setLastStartError(
        tunStopError == null
            ? _friendlyStartException(e)
            : (_startupDisabledReason ?? 'TUN DNS 恢复失败'),
      );
      log('启动核心异常: $e');
      log('堆栈: $stack');
      await _stopInternal(priorTunStopError: tunStopError);
      return false;
    }
  }

  Future<bool> _recoverPendingTunDnsInternal(int startToken) async {
    final tunSession = _tunSession;
    if (tunSession == null) {
      const reason = 'TUN DNS 恢复服务尚未初始化';
      disableStartup(reason);
      notifyStatusChanged();
      return false;
    }

    log('检测到待恢复的 TUN DNS，正在当前进程重试恢复...');
    final recovered = await tunSession.recoverStaleDnsIfNeeded();
    _ensureStartCurrent(startToken);
    if (!recovered) {
      final reason = tunSession.lastError ?? 'TUN DNS 恢复尚未完成，已暂停新连接';
      disableStartup(reason);
      notifyStatusChanged();
      return false;
    }

    _startupBlockedByTunDnsRecovery = false;
    if (_startupBlockedByProxyRecovery || _proxyService.recoveryPending) {
      notifyStatusChanged();
      return true;
    }

    try {
      if (!_coreAssetsPrepared) {
        await _prepareCoreAssetsAfterProxyRecovery(
          runVersionProbe: _runCoreProbesAfterRecovery,
        );
        _ensureStartCurrent(startToken);
      }
      _startupDisabledReason = null;
      setLastStartError(null);
      log('✅ TUN DNS 已恢复，可继续连接');
      notifyStatusChanged();
      return true;
    } catch (error) {
      // Keep the same retry path active. The DNS marker is already safe, but a
      // later click can retry the core preparation without restarting the app.
      _startupBlockedByTunDnsRecovery = true;
      final reason = 'TUN DNS 已恢复，但 Mihomo 核心安全准备失败: $error';
      disableStartup(reason);
      notifyStatusChanged();
      return false;
    }
  }

  @override
  void interruptPendingStart() {
    _startGeneration++;
    final cancellation = _startCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _tunSession?.interruptPendingStart();
  }

  @override
  Future<void> stop() {
    interruptPendingStart();
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopAfterStart();
    _stopOperation = operation;
    operation.then<void>(
      (_) => _clearStopOperation(operation),
      onError: (_, __) => _clearStopOperation(operation),
    );
    return operation;
  }

  Future<void> _stopAfterStart() async {
    final starting = _startOperation;
    Object? tunStopError;
    if (starting != null) {
      final tunSession = _tunSession;
      if (tunSession != null && tunSession.isRequested) {
        try {
          await _stopTunSession(tunSession);
        } catch (error) {
          tunStopError = error;
        }
      }
      await starting;
    }
    final proxyCleared = await _stopInternal(
      priorTunStopError: tunStopError,
    );
    if (!proxyCleared) {
      throw StateError(
        lastStartError ??
            _proxyService.lastError ??
            'macOS 系统代理或 Mihomo 核心未能安全停止，请再次尝试断开',
      );
    }
  }

  Future<bool> _stopInternal({Object? priorTunStopError}) async {
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    await _cancelNativeCoreStatusWatch();
    stopStatusMonitor();
    resetHealthCheckFailures();
    _invalidateTunDataPathProbe();

    final tunSession = _tunSession;
    var tunStopError = priorTunStopError;
    if (tunStopError == null && tunSession != null && tunSession.isRequested) {
      try {
        await _stopTunSession(tunSession);
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (DateTime.now().isBefore(deadline)) {
          if (!await healthCheck()) break;
          await Future.delayed(const Duration(milliseconds: 100));
        }
        log('macOS TUN 授权会话已停止');
      } catch (error) {
        tunStopError ??= error;
      }
    }

    final proxyCleared = await _proxyService.clearSystemProxy();
    if (!proxyCleared) {
      if (_proxyService.lastError != null) {
        log(_proxyService.lastError!);
      }
      final activeCore = _clashProcess;
      if (activeCore != null) _scheduleNativeCoreStatusWatch(activeCore);
      if (isRunning) startStatusMonitor();
      notifyStatusChanged();
      return false;
    }

    // The system no longer routes through SSRVPN. Publish that user-visible
    // fact before process cleanup; a surviving orphan is a cleanup error, not
    // an active connection.
    setRunning(false);
    notifyStatusChanged();

    final process = _clashProcess;
    final expectedRecord = _corePidRecordContents;
    if (process != null || expectedRecord != null) {
      _stoppingCore = true;
      var terminated = false;
      try {
        if (expectedRecord != null) {
          terminated = await _coreProcessChannel.invokeMethod<bool>(
                'terminateOwnedCoreRecord',
                {
                  'directory': configDir,
                  'expectedContents': expectedRecord,
                },
              ) ==
              true;
        }
      } catch (e) {
        log('停止核心异常: $e');
      } finally {
        _stoppingCore = false;
      }
      if (!terminated) {
        setLastStartError('无法确认 Mihomo 核心已退出，已保留进程状态并拒绝重新启动');
        log('❌ $lastStartError');
        final activeCore = _clashProcess;
        if (activeCore != null) _scheduleNativeCoreStatusWatch(activeCore);
        return false;
      }
      _clashProcess = null;
      _corePidRecordContents = null;
    }

    setRunning(false);
    notifyStatusChanged();
    log('Mihomo 核心已停止');
    return tunStopError == null;
  }

  Future<void> _stopTunSession(MacosTunSession tunSession) async {
    try {
      await tunSession.stop();
    } catch (_) {
      if (tunSession.requiresDnsRecovery) {
        _markTunDnsRecoveryRequired(tunSession);
      } else if (tunSession.lastError != null) {
        setLastStartError(tunSession.lastError);
      }
      rethrow;
    }
  }

  void _markTunDnsRecoveryRequired(MacosTunSession tunSession) {
    _invalidateTunDataPathProbe();
    _startupBlockedByTunDnsRecovery = true;
    final reason =
        tunSession.lastError ?? 'TUN DNS 未能安全恢复，已阻止重新连接；请重启 SSRVPN 完成恢复';
    disableStartup(reason);
    setRunning(false);
    notifyStatusChanged();
  }

  Future<bool> _startTunCore(int startToken, Stopwatch startupWatch) async {
    final tunSession = _tunSession;
    if (tunSession == null) {
      setLastStartError('TUN 授权服务尚未初始化');
      return false;
    }

    _beginTunDataPathSession();

    log('正在请求 macOS 管理员授权以启动本次 TUN 连接...');
    if (!await tunSession.start()) {
      _ensureStartCurrent(startToken);
      setLastStartError(tunSession.lastError ?? 'TUN 管理员授权失败');
      log(lastStartError!);
      return false;
    }

    var stopAttempted = false;
    Future<void> stopTunAfterStart() async {
      if (stopAttempted || !tunSession.isRequested) return;
      stopAttempted = true;
      await _stopTunSession(tunSession);
    }

    try {
      _ensureStartCurrent(startToken);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        _ensureStartCurrent(startToken);
        final startupState = await tunSession.startupState();
        _ensureStartCurrent(startToken);
        if (startupState == MacosTunStartupState.failed) {
          setLastStartError(tunSession.lastError ?? 'TUN 核心启动失败');
          log(lastStartError!);
          await stopTunAfterStart();
          return false;
        }
        if (startupState != MacosTunStartupState.running) {
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }
        if (await healthCheck()) {
          final connectivityWarning = await verifyUserConnectivity(
            shouldContinue: () => startToken == _startGeneration,
          );
          _ensureStartCurrent(startToken);
          if (connectivityWarning != null) {
            _lastTunDataPathProbeAt = DateTime.now();
            _lastTunDataPathHealthy = false;
            _consecutiveTunDataPathFailures = 1;
            setConnectivityWarning(
              '节点或外部网络暂时不可用，TUN 保持连接并继续恢复：'
              '$connectivityWarning',
            );
            log(
              'EXTERNAL_CHECK_BLOCKED (startup advisory): '
              '$connectivityWarning',
            );
          } else {
            _lastTunDataPathProbeAt = DateTime.now();
            _lastTunDataPathHealthy = true;
            _consecutiveTunDataPathFailures = 0;
            setConnectivityWarning(null);
          }
          final finalControlPlaneHealthy =
              await _verifyTunFinalControlPlaneHealth(tunSession);
          _ensureStartCurrent(startToken);
          if (!finalControlPlaneHealthy) {
            setLastStartError(lastHealthCheckError ?? 'TUN 启动最终复核失败');
            log(lastStartError!);
            await stopTunAfterStart();
            return false;
          }
          setRunning(true);
          resetHealthCheckFailures();
          log(
            'macOS TUN 核心、服务与配置已就绪，耗时 '
            '${startupWatch.elapsedMilliseconds}ms',
          );
          notifyStatusChanged();
          startStatusMonitor();
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
      final healthDetail = lastHealthCheckError;
      setLastStartError(
        healthDetail == null
            ? 'TUN 核心启动超时，请重试'
            : 'TUN 核心未能通过健康检查：$healthDetail',
      );
      log(lastStartError!);
      await stopTunAfterStart();
      return false;
    } on _DesktopStartCancelled {
      await stopTunAfterStart();
      rethrow;
    } catch (error) {
      await stopTunAfterStart();
      rethrow;
    }
  }

  void _beginTunDataPathSession() {
    _tunDataPathProbeGeneration++;
    _tunDataPathProbe = null;
    _lastTunDataPathProbeAt = null;
    _lastTunDataPathHealthy = true;
    _consecutiveTunDataPathFailures = 0;
    setConnectivityWarning(null);
  }

  void _invalidateTunDataPathProbe() {
    _tunDataPathProbeGeneration++;
    _tunDataPathProbe = null;
  }

  void _ensureStartCurrent(int startToken) {
    if (startToken != _startGeneration) throw _DesktopStartCancelled();
  }

  Future<MacosNativeCoreStatus> _readNativeCoreStatus(
    MacosNativeCoreHandle handle,
  ) async {
    final value = await _coreProcessChannel.invokeMethod<Object?>(
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
    final watcher = _nativeCoreStatusWatcher;
    if (watcher != null) await watcher;
  }

  Future<void> _watchNativeCoreStatus(
    MacosNativeCoreHandle handle,
    int generation,
  ) async {
    bool isCurrent() =>
        generation == _nativeCoreStatusWatchGeneration &&
        identical(_clashProcess, handle);

    while (isCurrent()) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
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

  Future<bool> _removeOwnedCorePidRecord({String? expectedContents}) async {
    final contents = expectedContents ?? _corePidRecordContents;
    if (contents == null) return true;
    try {
      final removed = await _coreProcessChannel.invokeMethod<bool>(
        'removeOwnedCorePidRecord',
        {'directory': configDir, 'expectedContents': contents},
      );
      if (removed == true) {
        if (_corePidRecordContents == contents) {
          _corePidRecordContents = null;
        }
        return true;
      }
      log('核心进程身份记录已变化，保留现有记录');
      return false;
    } catch (error) {
      log('删除核心进程身份记录失败: $error');
      return false;
    }
  }

  void _scheduleUnexpectedExitCleanup(int exitCode, int? recoveryGeneration,
      {required bool usedSystemProxy}) {
    final cleanup = _prepareUnexpectedExitProxyCleanup(
      recoveryGeneration,
      usedSystemProxy: usedSystemProxy,
    );
    final cleanupBarrier = cleanup.then<void>((_) {});
    _exitCleanupOperation = cleanupBarrier;
    unawaited(() async {
      final proxyCleanup = await cleanup;
      if (identical(_exitCleanupOperation, cleanupBarrier)) {
        _exitCleanupOperation = null;
      }
      await _recoverAfterUnexpectedExit(
        exitCode,
        recoveryGeneration,
        proxyCleanup,
      );
    }());
  }

  Future<DesktopUnexpectedExitProxyCleanupResult>
      _prepareUnexpectedExitProxyCleanup(
    int? recoveryGeneration, {
    required bool usedSystemProxy,
  }) async {
    SystemProxyOwnershipStatus? ownershipBeforeClear;
    if (usedSystemProxy) {
      try {
        ownershipBeforeClear = await inspectSystemProxyOwnership();
      } catch (error) {
        ownershipBeforeClear = SystemProxyOwnershipStatus.unavailable;
        log('核心异常退出前无法确认系统代理所有权: $error');
      }
      if (ownershipBeforeClear != SystemProxyOwnershipStatus.owned &&
          recoveryGeneration != null &&
          isConnectionIntentCurrent(recoveryGeneration, connected: true)) {
        // Clear/discard SSRVPN's recovery state, but invalidate restart intent
        // before that asynchronous cleanup can race with another recovery.
        markConnectionLost();
      }
    }

    var proxyRecovered = false;
    try {
      proxyRecovered = await clearSystemProxyAfterUnexpectedExit();
      if (!proxyRecovered && _proxyService.lastError != null) {
        log(_proxyService.lastError!);
      }
    } catch (error) {
      log('核心异常退出后清理系统代理失败: $error');
    }
    final ownershipChangedDuringClear =
        usedSystemProxy && systemProxyOwnershipChangedSinceLastAcquisition;
    if (ownershipChangedDuringClear &&
        recoveryGeneration != null &&
        isConnectionIntentCurrent(recoveryGeneration, connected: true)) {
      markConnectionLost();
    }
    return DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: proxyRecovered,
      ownershipBeforeClear: ownershipBeforeClear,
      ownershipChangedDuringClear: ownershipChangedDuringClear,
    );
  }

  @protected
  Future<bool> clearSystemProxyAfterUnexpectedExit() =>
      _proxyService.clearSystemProxy();

  Future<void> _recoverAfterUnexpectedExit(
    int exitCode,
    int? recoveryGeneration,
    DesktopUnexpectedExitProxyCleanupResult proxyCleanup,
  ) async {
    if (proxyCleanup.hasUnsafeSystemProxyOwnership) {
      final changedDuringClear = proxyCleanup.ownershipChangedDuringClear;
      final externallyChanged = proxyCleanup.ownershipBeforeClear ==
          SystemProxyOwnershipStatus.externallyChanged;
      _lastUnexpectedExitNotice = proxyCleanup.proxyCleared
          ? (changedDuringClear
              ? 'Mihomo 异常退出（退出码 $exitCode）；系统代理在清理期间发生变化，'
                  'SSRVPN 已取消自动重连，不会重新接管当前代理。'
              : externallyChanged
                  ? 'Mihomo 异常退出（退出码 $exitCode）；检测到系统代理已由其他程序接管，'
                      'SSRVPN 已清理自身恢复状态并取消自动重连，未覆盖当前代理。'
                  : 'Mihomo 异常退出（退出码 $exitCode）；此前无法确认系统代理所有权，'
                      'SSRVPN 已完成清理并取消自动重连，不会重新接管代理。')
          : 'Mihomo 异常退出（退出码 $exitCode）；已取消自动重连，但系统代理恢复状态'
              '清理无法确认。请在诊断页检查并重试断开，SSRVPN 不会重新接管代理。';
      try {
        onProcessExit?.call();
      } catch (error) {
        log('核心退出回调失败: $error');
      }
      return;
    }

    var automaticallyRecovered = false;
    if (proxyCleanup.permitsAutomaticRestart &&
        recoveryGeneration != null &&
        isConnectionIntentCurrent(recoveryGeneration, connected: true) &&
        _automaticRecoveryPolicy.tryAcquire()) {
      notifyRuntimeNotice('Mihomo 异常退出（退出码 $exitCode），正在自动恢复…');
      automaticallyRecovered = await runConnectionTransition(() async {
        if (!isConnectionIntentCurrent(
          recoveryGeneration,
          connected: true,
        )) {
          return false;
        }
        return recoverDesktopConnection(recoveryGeneration);
      });
    }

    final intentCurrent = recoveryGeneration != null &&
        isConnectionIntentCurrent(recoveryGeneration, connected: true);
    if (automaticallyRecovered && intentCurrent && isRunning) {
      _lastUnexpectedExitNotice = 'Mihomo 异常退出（退出码 $exitCode），连接已自动恢复。';
    } else {
      if (intentCurrent) markConnectionLost();
      _lastUnexpectedExitNotice = buildMacosUnexpectedExitNotice(
        exitCode: exitCode,
        proxyRecovered: proxyCleanup.proxyCleared,
      );
    }
    try {
      onProcessExit?.call();
    } catch (error) {
      log('核心退出回调失败: $error');
    }
  }

  @protected
  Future<void> runUnexpectedExitRecovery({
    required int? generation,
    required int exitCode,
    bool usedTun = false,
  }) async {
    final proxyCleanup = await _prepareUnexpectedExitProxyCleanup(
      generation,
      usedSystemProxy: !usedTun,
    );
    await _recoverAfterUnexpectedExit(
      exitCode,
      generation,
      proxyCleanup,
    );
  }

  void _clearStartOperation(Future<bool> operation) {
    if (identical(_startOperation, operation)) {
      _startOperation = null;
      _startCancellation = null;
    }
  }

  void _clearStopOperation(Future<void> operation) {
    if (identical(_stopOperation, operation)) {
      _stopOperation = null;
    }
  }

  Future<bool> _validateConfig(Map<String, String> environment) async {
    log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    try {
      await _verifyCoreForExecution();
      final result = await _runProcess(
        _corePath,
        ['-t', '-d', configDir, '-f', configPath],
        workingDirectory: configDir,
        includeParentEnvironment: true,
        environment: environment,
        timeout: const Duration(seconds: 40),
        cancellation: _startCancellation?.future,
      );
      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (stdout.isNotEmpty) log('[配置校验] $stdout');
      if (stderr.isNotEmpty) log('[配置校验 stderr] $stderr');
      if (result.exitCode == 0) {
        log('Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (result.exitCode == 125) throw _DesktopStartCancelled();
      if (result.exitCode == 124) {
        setLastStartError('电脑性能不足或配置校验超时，请重新连接');
      } else if (stderr.isNotEmpty || stdout.isNotEmpty) {
        setLastStartError(
          'Mihomo 配置校验失败: ${stderr.isNotEmpty ? stderr : stdout}',
        );
      }
      log('Mihomo 配置校验失败，退出码: ${result.exitCode}');
      return false;
    } on _DesktopStartCancelled {
      rethrow;
    } catch (e) {
      setLastStartError(_friendlyStartException(e));
      log('无法执行 Mihomo 配置校验: $e');
      return false;
    }
  }

  String _friendlyStartException(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('permission denied') ||
        lower.contains('operation not permitted') ||
        lower.contains('权限') ||
        lower.contains('拒绝')) {
      return '无法执行 Mihomo，核心文件权限异常';
    }
    if (lower.contains('bad cpu type') ||
        lower.contains('exec format') ||
        lower.contains('unsupported architecture')) {
      return 'Mihomo 与当前 Mac 架构不兼容';
    }
    return '启动 Mihomo 时发生异常: $message';
  }

  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool includeParentEnvironment = true,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 10),
    Future<void>? cancellation,
  }) =>
      TimedProcessRunner.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        includeParentEnvironment: includeParentEnvironment,
        environment: environment,
        timeout: timeout,
        cancellation: cancellation,
      );
}
