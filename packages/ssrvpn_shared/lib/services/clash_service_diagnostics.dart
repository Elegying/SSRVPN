part of 'clash_service_base.dart';

/// Read-only diagnostics and narrowly scoped, platform-owned repair hooks.
mixin _ClashDiagnosticsSupport {
  bool get isRunning;
  String? get lastStartError;
  String? get lastRuntimePortAdjustmentMessage;
  String? get connectivityWarning;
  String get recentLogs;
  String get configPath;

  Future<bool> healthCheck();

  /// Platforms override this with their trusted core-file check.
  @protected
  Future<bool> diagnosticCoreAvailable() async => true;

  /// Platforms with versioned runtime snapshots can expose the file that the
  /// active core actually owns instead of the nominal next-start path.
  @protected
  String get diagnosticConfigPath => configPath;

  /// A platform can skip this check when it creates an ephemeral runtime
  /// config only as part of a connection attempt.
  @protected
  bool get diagnosticConfigRequired => true;

  /// Platforms can append checks for state they exclusively own, such as the
  /// system-proxy recovery journal. Diagnostics must not mutate that state.
  @protected
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];

  Future<AppDiagnosticReport> runDiagnostics({
    DateTime Function()? clock,
  }) async {
    final checks = <AppDiagnosticCheck>[];

    var coreAvailable = false;
    try {
      coreAvailable = await diagnosticCoreAvailable();
    } catch (_) {}
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
      var configAvailable = false;
      try {
        configAvailable =
            await FileSystemEntity.type(configuredPath, followLinks: false) ==
                FileSystemEntityType.file;
      } catch (_) {}
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
          title: '核心通信',
          status: AppDiagnosticStatus.skipped,
          summary: '当前未连接，无需检查核心 API',
        ),
      );
    } else {
      var healthy = false;
      try {
        healthy = await healthCheck();
      } catch (_) {}
      checks.add(
        AppDiagnosticCheck(
          id: 'runtime',
          title: '核心通信',
          status:
              healthy ? AppDiagnosticStatus.passed : AppDiagnosticStatus.failed,
          summary: healthy ? '本地核心 API 响应正常' : '本地核心 API 无法访问',
          errorCode: healthy ? null : AppErrorCode.coreUnavailable,
        ),
      );
    }

    final dataPlaneWarning = connectivityWarning?.trim();
    if (isRunning && dataPlaneWarning != null && dataPlaneWarning.isNotEmpty) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'data_plane',
          title: '节点与外部网络',
          status: AppDiagnosticStatus.warning,
          summary: '数据通道处于降级恢复状态；核心、系统服务和运行配置仍保持连接',
          errorCode: AppErrorCode.dataPlaneDegraded,
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

    try {
      checks.addAll(await platformDiagnosticChecks());
    } catch (_) {
      checks.add(
        const AppDiagnosticCheck(
          id: 'platform',
          title: '平台状态',
          status: AppDiagnosticStatus.warning,
          summary: '平台检查未能完成，未修改任何系统状态',
          errorCode: AppErrorCode.unknown,
        ),
      );
    }

    return AppDiagnosticReport(
      generatedAt: (clock ?? DateTime.now)(),
      checks: checks,
      recentLogs: recentLogs,
    );
  }

  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async {
    return const AppRepairResult(
      success: false,
      message: '当前平台没有可执行的安全修复操作。',
    );
  }
}
