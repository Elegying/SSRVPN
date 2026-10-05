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

/// 诊断页展示的数据面结论文案。
///
/// 诊断读的是**缓存告警**而不是重新探测：完整探测最坏约 41 秒（6 次尝试 ×
/// 6 秒超时 + 5 次 1 秒间隔），远超 [diagnosticCheckTimeout] 的 10 秒预算。
/// 既然无法在诊断时刷新，就必须把观察时间一并说出来，否则用户无法判断
/// 「暂未通过」是当前状态还是几十秒前的旧状态。
///
/// [now] 由调用方传入而不是内部取 `DateTime.now()`，便于测试时间窗边界。
String buildDataPlaneDiagnosticSummary({
  required DateTime? observedAt,
  required DateTime now,
}) {
  const base = '外部探测未通过，实际访问情况尚未确认';
  if (observedAt == null) return base;
  final seconds = now.difference(observedAt).inSeconds;
  // 时钟回拨、或跨会话残留的旧时间戳，都不足以支撑「刚刚观察过」的措辞。
  if (seconds < 0 || seconds > 3600) return base;
  return '$base（最近一次观察 $seconds 秒前）';
}

/// Read-only diagnostics and narrowly scoped, platform-owned repair hooks.
mixin _ClashDiagnosticsSupport implements ClashPlatformDiagnosticCapability {
  bool get _canPublishHealthCheckResult;
  bool get isDataPlaneObservationCurrent;

  // A live connection can change networks without changing health or intent.
  bool get _canPublishDiagnosticResult =>
      _canPublishHealthCheckResult && isDataPlaneObservationCurrent;
  static int _nextLogSession = 0;
  static const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

  String _logBuffer = '';
  late final String _logSessionId =
      '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}-'
      '${(_nextLogSession++).toRadixString(36)}';

  void Function(String message)? onLog;

  bool get isRunning;
  bool get connectionDesired;
  int get desiredApiPort;
  int get runtimeApiPort;
  String _apiUrl(String path);
  String? get lastStartError;
  String? get lastHealthCheckError;
  String? get lastRuntimePortAdjustmentMessage;
  String? get connectivityWarning;
  String? get dataPlaneConnectivityWarning;

  /// 最近一次数据面观察完成的时间；null 表示平台没有可用的时间戳。
  DateTime? get dataPlaneObservationAt;
  DateTime? get dataPlaneResultAt;
  String get recentLogs => _logBuffer;
  String get configPath;
  @protected
  Duration get diagnosticCheckTimeout => const Duration(seconds: 10);

  /// Returns the best currently available data-plane warning for a manual
  /// diagnostic run. Platforms may override this to query an authoritative,
  /// read-only network snapshot before the report is classified.
  @protected
  Future<String?> diagnosticDataPlaneWarning() async =>
      dataPlaneConnectivityWarning;
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  }) {
    final sanitized = LogRedactor.sanitize(
      message,
    ).replaceAll(RegExp(r'[\r\n]+'), ' ↩ ');
    final normalizedEvent = event.trim().toLowerCase();
    final safeEvent =
        RegExp(r'^[a-z0-9][a-z0-9_.-]{0,47}$').hasMatch(normalizedEvent)
            ? normalizedEvent
            : 'runtime';
    final line = '[${DateTime.now().toUtc().toIso8601String()}] '
        '[${level.name.toUpperCase()}] [$safeEvent] '
        '[session=$_logSessionId] $sanitized';
    _logBuffer = '$line\n$_logBuffer';
    if (_logBuffer.length > AppConstants.maxLogBufferSize) {
      final completeLineEnd =
          _logBuffer.lastIndexOf('\n', AppConstants.maxLogBufferSize - 1);
      _logBuffer = _logBuffer.substring(
        0,
        completeLineEnd >= 0
            ? completeLineEnd + 1
            : AppConstants.maxLogBufferSize,
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
  Future<T> runDiagnosticInSession<T>(Future<T> Function() operation);

  Future<bool> diagnosticRecentIPv6Failure() async => false;

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
    if (!_canPublishDiagnosticResult) throw const _DiagnosticSessionChanged();
    try {
      return await operation().timeout(diagnosticCheckTimeout);
    } on TimeoutException {
      if (_canPublishDiagnosticResult) log('诊断检查 $id 超时');
      return null;
    } catch (error) {
      if (_canPublishDiagnosticResult) {
        log('诊断检查 $id 失败: cause=${safeRuntimeErrorCode(error)}');
      }
      return null;
    } finally {
      if (!_canPublishDiagnosticResult) {
        throw const _DiagnosticSessionChanged();
      }
    }
  }

  Future<AppDiagnosticReport> runDiagnostics({DateTime Function()? clock}) =>
      runDiagnosticInSession(() async {
        try {
          final report = await _runDiagnostics(clock: clock);
          if (!_canPublishDiagnosticResult) {
            throw const _DiagnosticSessionChanged();
          }
          return report;
        } on _DiagnosticSessionChanged {
          return AppDiagnosticReport(
            generatedAt: (clock ?? DateTime.now)(),
            checks: const [
              AppDiagnosticCheck(
                id: 'session_changed',
                title: '连接已变化',
                status: AppDiagnosticStatus.skipped,
                summary: '诊断期间连接已变化，请重新检查',
              )
            ],
            recentLogs: '',
          );
        }
      });

  Future<AppDiagnosticReport> _runDiagnostics({
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
          summary:
              healthy ? '本地核心 API、运行配置与必要监听响应正常' : healthFailure!.userMessage,
          errorCode: healthFailure?.code,
        ),
      );
    }

    final diagnosticEndpoint = Uri.parse(_apiUrl('/version'));
    final actualPort = runtimeApiPort;
    final desiredPort = desiredApiPort;
    bool? listening;
    if (isRunning) {
      listening = await _runDiagnosticCheck('api_listener', () async {
        Socket? socket;
        try {
          socket = await Socket.connect(
              InternetAddress.loopbackIPv4, actualPort,
              timeout: const Duration(seconds: 1));
          return true;
        } on SocketException {
          return false;
        } finally {
          socket?.destroy();
        }
      });
    }
    final endpointChanged = actualPort != runtimeApiPort;
    final mismatch = diagnosticEndpoint.port != actualPort;
    checks.add(AppDiagnosticCheck(
      id: 'controller_endpoint',
      title: '本地控制端口',
      status: endpointChanged
          ? AppDiagnosticStatus.skipped
          : mismatch
              ? AppDiagnosticStatus.failed
              : listening == false
                  ? AppDiagnosticStatus.warning
                  : AppDiagnosticStatus.passed,
      summary: endpointChanged
          ? '诊断期间连接已变化，请重新检查'
          : '预期端口 $desiredPort；实际端口 $actualPort；'
              '健康检查端口 ${diagnosticEndpoint.port}；'
              '监听：${listening == null ? '未确认' : listening ? '是' : '否'}。'
              '${mismatch ? '运行端口与健康检查端口不一致。' : ''}'
              '${actualPort != desiredPort ? '本地控制端口发生自动调整，这是正常的冲突保护机制。' : ''}'
              '会话：${isRunning ? '运行中' : connectionDesired ? '等待连接' : '已断开'}。',
    ));

    // A completed check may legitimately have no warning. Keep that separate
    // from the null returned when the check itself fails or times out.
    final dataPlaneResult = isRunning
        ? await _runDiagnosticCheck(
            'data_plane',
            () async {
              final platformWarning = await diagnosticDataPlaneWarning();
              // A probe can finish while the platform snapshot is pending.
              // A stale null snapshot must not hide its newly published failure.
              final warning = platformWarning ?? dataPlaneConnectivityWarning;
              return (
                warning: warning,
                observedAt: warning == dataPlaneConnectivityWarning
                    ? dataPlaneResultAt
                    : null,
              );
            },
          )
        : null;
    final dataPlaneWarning = dataPlaneResult?.warning?.trim();
    if (isRunning && dataPlaneResult == null) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'data_plane',
          title: '节点与外部网络',
          status: AppDiagnosticStatus.warning,
          summary: '检查未完成，暂时无法判断外部网络状态；请重新检查',
        ),
      );
    } else if (isRunning &&
        dataPlaneWarning != null &&
        dataPlaneWarning.isNotEmpty) {
      checks.add(
        AppDiagnosticCheck(
          id: 'data_plane',
          title: '节点与外部网络',
          status: AppDiagnosticStatus.warning,
          summary: buildDataPlaneDiagnosticSummary(
            observedAt: dataPlaneResult?.observedAt,
            now: (clock ?? DateTime.now)(),
          ),
          errorCode: AppErrorCode.dataPlaneDegraded,
        ),
      );
    } else if (isRunning) {
      final observedAt = dataPlaneResult?.observedAt;
      final age = observedAt == null
          ? null
          : (clock ?? DateTime.now)().difference(observedAt).inSeconds;
      final verified = age != null && age >= 0 && age <= 3600;
      checks.add(
        AppDiagnosticCheck(
          id: 'data_plane',
          title: '节点与外部网络',
          status: verified
              ? AppDiagnosticStatus.passed
              : AppDiagnosticStatus.warning,
          summary: verified
              ? '最近一次外部网络验证通过（$age 秒前）；不代表所有网站均可访问'
              : observedAt == null
                  ? '外部网络验证尚未完成，实际访问情况尚未确认；请稍后重新检查'
                  : '外部网络验证结果已过期，实际访问情况尚未确认；请稍后重新检查',
        ),
      );
    }

    // IPv6 target failures remain in the core logs. They do not establish
    // node-wide failure and must not add a user-facing warning check.

    final startError = lastStartError?.trim();
    if (startError != null && startError.isNotEmpty) {
      final failure = AppFailure.fromMessage(startError);
      checks.add(
        AppDiagnosticCheck(
          id: 'last_start',
          title: '最近一次启动',
          status: AppDiagnosticStatus.warning,
          summary: failure.userMessage,
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
        (_) => _canPublishDiagnosticResult
            ? AppDiagnosticHistoryStore(
                '$configDir${Platform.pathSeparator}diagnostic-history.json',
              ).append(report)
            : Future<void>.value(),
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

class _DiagnosticSessionChanged implements Exception {
  const _DiagnosticSessionChanged();
}
