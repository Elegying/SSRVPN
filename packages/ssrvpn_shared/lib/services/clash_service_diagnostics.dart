part of 'clash_service_base.dart';

/// Platform-owned information required by the shared diagnostic runner.
///
/// Every concrete platform must implement every member. There are deliberately
/// no "healthy" defaults: adding a platform without diagnostics must fail at
/// compile time instead of silently reporting success.
abstract interface class ClashPlatformDiagnosticCapability {
  Future<bool> diagnosticCoreAvailable();
  String get diagnosticConfigPath;
  bool get diagnosticConfigRequired;
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks();
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action);
}

/// Read-only diagnostics and narrowly scoped, platform-owned repair hooks.
mixin _ClashDiagnosticsSupport implements ClashPlatformDiagnosticCapability {
  static int _nextLogSession = 0;
  static const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

  String _logBuffer = '';
  late final String _logSessionId =
      '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}-'
      '${(_nextLogSession++).toRadixString(36)}';

  void Function(String message)? onLog;

  bool get isRunning;
  String? get lastStartError;
  String? get lastHealthCheckError;
  String? get lastRuntimePortAdjustmentMessage;
  String? get connectivityWarning;
  String? get dataPlaneConnectivityWarning;
  String get recentLogs => _logBuffer;
  String get configPath;
  @protected
  Duration get diagnosticCheckTimeout => const Duration(seconds: 10);
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  }) {
    final sanitized = LogRedactor.sanitize(message).replaceAll(
      RegExp(r'[\r\n]+'),
      ' ↩ ',
    );
    final normalizedEvent = event.trim().toLowerCase();
    final safeEvent =
        RegExp(r'^[a-z0-9][a-z0-9_.-]{0,47}$').hasMatch(normalizedEvent)
            ? normalizedEvent
            : 'runtime';
    final line = '[${DateTime.now().toUtc().toIso8601String()}] '
        '[${level.name.toUpperCase()}] [$safeEvent] '
        '[session=$_logSessionId] $sanitized';
    _logBuffer = '$line\n$_logBuffer';
    if (_logBuffer.length > 10000) {
      final completeLineEnd = _logBuffer.lastIndexOf('\n', 9999);
      _logBuffer = _logBuffer.substring(
        0,
        completeLineEnd >= 0 ? completeLineEnd + 1 : 10000,
      );
    }
    writePlatformLog(line);
    onLog?.call(line);
    if (!_kReleaseMode) debugLog(line);
  }

  /// Override for durable platform log files. [line] is already redacted,
  /// timestamped and normalized to one physical line.
  @protected
  void writePlatformLog(String line) {}

  /// Override for platform-specific debug output (debugPrint, file logging, etc.)
  @protected
  void debugLog(String message) {}
  String get configDir;

  Future<bool> healthCheck();

  @protected
  @override
  Future<bool> diagnosticCoreAvailable();

  @protected
  @override
  String get diagnosticConfigPath;

  @protected
  @override
  bool get diagnosticConfigRequired;

  @protected
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks();

  Future<void> _diagnosticHistoryTail = Future<void>.value();

  Future<T?> _runDiagnosticCheck<T>(
    String id,
    Future<T> Function() operation,
  ) async {
    try {
      return await operation().timeout(diagnosticCheckTimeout);
    } on TimeoutException {
      log('诊断检查 $id 超时');
      return null;
    } catch (error) {
      log('诊断检查 $id 失败: cause=${_safeRuntimeLogErrorCode(error)}');
      return null;
    }
  }

  Future<AppDiagnosticReport> runDiagnostics({
    DateTime Function()? clock,
  }) async {
    final checks = <AppDiagnosticCheck>[];

    final coreAvailable =
        await _runDiagnosticCheck('core', diagnosticCoreAvailable) ?? false;
    checks.add(
      AppDiagnosticCheck(
        id: 'core',
        title: '运行核心',
        status: coreAvailable
            ? AppDiagnosticStatus.passed
            : AppDiagnosticStatus.failed,
        summary: coreAvailable ? '核心文件可用' : '核心文件缺失或未通过安全检查',
        errorCode: coreAvailable ? null : AppErrorCode.coreMissing,
      ),
    );

    final configuredPath = diagnosticConfigPath.trim();
    if (!diagnosticConfigRequired) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'config',
          title: '运行配置',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查运行配置',
        ),
      );
    } else if (configuredPath.isEmpty) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'config',
          title: '运行配置',
          status: AppDiagnosticStatus.skipped,
          summary: '应用尚未完成初始化',
        ),
      );
    } else {
      final configType = await _runDiagnosticCheck(
        'config',
        () => FileSystemEntity.type(configuredPath, followLinks: false),
      );
      final configAvailable = configType == FileSystemEntityType.file;
      checks.add(
        AppDiagnosticCheck(
          id: 'config',
          title: '运行配置',
          status: configAvailable
              ? AppDiagnosticStatus.passed
              : AppDiagnosticStatus.failed,
          summary: configAvailable ? '配置文件可用' : '配置文件不存在或不是普通文件',
          errorCode: configAvailable ? null : AppErrorCode.configInvalid,
        ),
      );
    }

    if (!isRunning) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'runtime',
          title: '运行状态',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查本地运行状态',
        ),
      );
    } else {
      final healthy =
          await _runDiagnosticCheck('runtime', healthCheck) ?? false;
      final healthFailure = healthy
          ? null
          : AppFailure.fromMessage(
              lastHealthCheckError ?? 'CORE_API_UNAVAILABLE',
            );
      checks.add(
        AppDiagnosticCheck(
          id: 'runtime',
          title: '运行状态',
          status:
              healthy ? AppDiagnosticStatus.passed : AppDiagnosticStatus.failed,
          summary: healthy
              ? '本地核心 API、运行配置与必要监听响应正常'
              : '${healthFailure!.message} ${healthFailure.recommendedAction}',
          errorCode: healthFailure?.code,
        ),
      );
    }

    final dataPlaneWarning = dataPlaneConnectivityWarning?.trim();
    if (isRunning && dataPlaneWarning != null && dataPlaneWarning.isNotEmpty) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'data_plane',
          title: '节点与外部网络',
          status: AppDiagnosticStatus.warning,
          summary: '外部网络观察暂未通过；核心、系统服务和运行配置仍保持连接',
          errorCode: AppErrorCode.dataPlaneDegraded,
        ),
      );
    } else if (isRunning) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'data_plane',
          title: '节点与外部网络',
          status: AppDiagnosticStatus.passed,
          summary: '当前没有检测到数据通道降级',
        ),
      );
    }

    final startError = lastStartError?.trim();
    if (startError != null && startError.isNotEmpty) {
      final failure = AppFailure.fromMessage(startError);
      checks.add(
        AppDiagnosticCheck(
          id: 'last_start',
          title: '最近一次启动',
          status: AppDiagnosticStatus.warning,
          summary: '${failure.message} ${failure.recommendedAction}',
          errorCode: failure.code,
        ),
      );
    }

    final portNotice = lastRuntimePortAdjustmentMessage?.trim();
    if (portNotice != null && portNotice.isNotEmpty) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'ports',
          title: '运行端口',
          status: AppDiagnosticStatus.warning,
          summary: '启动时已自动改用可用的本地端口',
          errorCode: AppErrorCode.portOccupied,
        ),
      );
    }

    final platformChecks = await _runDiagnosticCheck(
      'platform',
      platformDiagnosticChecks,
    );
    if (platformChecks == null) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'platform',
          title: '平台状态',
          status: AppDiagnosticStatus.warning,
          summary: '平台检查未能完成，未修改任何系统状态',
          errorCode: AppErrorCode.unknown,
        ),
      );
    } else {
      checks.addAll(platformChecks);
    }

    final report = AppDiagnosticReport(
      generatedAt: (clock ?? DateTime.now)(),
      checks: checks,
      recentLogs: recentLogs,
    );
    if (configDir.trim().isNotEmpty) {
      final operation = _diagnosticHistoryTail.then(
        (_) => AppDiagnosticHistoryStore(
          '$configDir${Platform.pathSeparator}diagnostic-history.json',
        ).append(report),
      );
      _diagnosticHistoryTail = operation.catchError((Object error) {
        log('诊断历史写入失败');
      });
      await _diagnosticHistoryTail;
    }
    return report;
  }

  Future<List<AppDiagnosticHistoryEntry>> loadDiagnosticHistory() async {
    await _diagnosticHistoryTail;
    if (configDir.trim().isEmpty) return const [];
    return AppDiagnosticHistoryStore(
      '$configDir${Platform.pathSeparator}diagnostic-history.json',
    ).load();
  }
}
