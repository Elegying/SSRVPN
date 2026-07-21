import '../utils/log_redactor.dart';

enum AppErrorCode {
  coreMissing('CORE_MISSING'),
  coreStartTimeout('CORE_START_TIMEOUT'),
  coreUnavailable('CORE_UNAVAILABLE'),
  dataPlaneDegraded('DATA_PLANE_DEGRADED'),
  portOccupied('PORT_OCCUPIED'),
  permissionRequired('PERMISSION_REQUIRED'),
  proxyRecoveryPending('PROXY_RECOVERY_PENDING'),
  subscriptionPartial('SUBSCRIPTION_PARTIAL'),
  subscriptionChanged('SUBSCRIPTION_CHANGED'),
  subscriptionFailed('SUBSCRIPTION_FAILED'),
  configInvalid('CONFIG_INVALID'),
  updateFailed('UPDATE_FAILED'),
  unknown('UNKNOWN');

  const AppErrorCode(this.wireName);

  final String wireName;
}

class AppFailure {
  const AppFailure({
    required this.code,
    required this.title,
    required this.message,
    required this.recommendedAction,
  });

  final AppErrorCode code;
  final String title;
  final String message;
  final String recommendedAction;

  static AppFailure fromMessage(Object? error) {
    final text = error?.toString().trim().toLowerCase() ?? '';
    final code = _classify(text);
    final requiresAdministratorRelaunch = text.contains('以管理员身份运行');
    return switch (code) {
      AppErrorCode.coreMissing => const AppFailure(
          code: AppErrorCode.coreMissing,
          title: '核心文件不可用',
          message: '运行核心缺失或未通过完整性检查。',
          recommendedAction: '请重新安装官方安装包后重试。',
        ),
      AppErrorCode.coreStartTimeout => const AppFailure(
          code: AppErrorCode.coreStartTimeout,
          title: '核心启动超时',
          message: '运行核心未能在限定时间内就绪。',
          recommendedAction: '请重试；若持续失败，请运行诊断并复制报告。',
        ),
      AppErrorCode.coreUnavailable => const AppFailure(
          code: AppErrorCode.coreUnavailable,
          title: '核心连接中断',
          message: '应用暂时无法访问本地运行核心。',
          recommendedAction: '请断开后重新连接，或运行诊断确认核心状态。',
        ),
      AppErrorCode.dataPlaneDegraded => const AppFailure(
          code: AppErrorCode.dataPlaneDegraded,
          title: '节点连接正在恢复',
          message: '核心与系统网络接管仍正常，节点或外部网络暂时不可用。',
          recommendedAction: '请等待自动切换；若持续失败，可手动切换节点。',
        ),
      AppErrorCode.portOccupied => const AppFailure(
          code: AppErrorCode.portOccupied,
          title: '本地端口被占用',
          message: '所需本地端口正被其他程序使用。',
          recommendedAction: '请再次连接以自动选择可用端口。',
        ),
      AppErrorCode.permissionRequired => AppFailure(
          code: AppErrorCode.permissionRequired,
          title: '系统权限不足',
          message: '当前操作需要额外的系统授权。',
          recommendedAction: requiresAdministratorRelaunch
              ? '请退出 SSRVPN 后，以管理员身份重新运行。'
              : '请按系统提示授权；拒绝授权不会修改网络设置。',
        ),
      AppErrorCode.proxyRecoveryPending => const AppFailure(
          code: AppErrorCode.proxyRecoveryPending,
          title: '系统代理待恢复',
          message: 'SSRVPN 自有的系统代理状态尚未完全恢复。',
          recommendedAction: '请保持断开状态并使用“修复系统代理”。',
        ),
      AppErrorCode.subscriptionPartial => const AppFailure(
          code: AppErrorCode.subscriptionPartial,
          title: '部分订阅刷新失败',
          message: '已有可用订阅继续保留，但部分来源未能更新。',
          recommendedAction: '请检查失败来源后重试，不必删除现有订阅。',
        ),
      AppErrorCode.subscriptionChanged => const AppFailure(
          code: AppErrorCode.subscriptionChanged,
          title: '订阅已更新',
          message: '连接准备期间订阅内容发生了变化，旧配置未启动。',
          recommendedAction: '请重新点击连接，以使用最新订阅配置。',
        ),
      AppErrorCode.subscriptionFailed => const AppFailure(
          code: AppErrorCode.subscriptionFailed,
          title: '订阅刷新失败',
          message: '本次未获得可用的订阅内容。',
          recommendedAction: '请检查订阅地址和网络后重试。',
        ),
      AppErrorCode.configInvalid => const AppFailure(
          code: AppErrorCode.configInvalid,
          title: '配置不可用',
          message: '生成或导入的配置未通过格式验证。',
          recommendedAction: '请刷新订阅；若持续失败，请运行诊断。',
        ),
      AppErrorCode.updateFailed => const AppFailure(
          code: AppErrorCode.updateFailed,
          title: '更新失败',
          message: '更新检查、下载或校验未能完成。',
          recommendedAction: '当前版本仍可使用，请稍后重试或从官网下载。',
        ),
      AppErrorCode.unknown => const AppFailure(
          code: AppErrorCode.unknown,
          title: '操作未完成',
          message: '发生了未分类的本地错误，原始敏感细节不会显示。',
          recommendedAction: '请运行诊断并复制脱敏报告。',
        ),
    };
  }

  static AppErrorCode _classify(String text) {
    bool hasAny(Iterable<String> values) => values.any(text.contains);

    if (hasAny(const ['address already in use', 'port occupied', '端口被占用']) ||
        (text.contains('bind') && text.contains('port'))) {
      return AppErrorCode.portOccupied;
    }
    if (hasAny(const [
      'access is denied',
      'permission denied',
      'administrator required',
      '权限不足',
      '需要管理员',
      '需要授权',
      '以管理员身份运行',
    ])) {
      return AppErrorCode.permissionRequired;
    }
    if (hasAny(const [
      '系统代理恢复失败',
      '代理待恢复',
      'proxy recovery',
      'restore proxy',
    ])) {
      return AppErrorCode.proxyRecoveryPending;
    }
    if (hasAny(const ['部分订阅', 'partial subscription'])) {
      return AppErrorCode.subscriptionPartial;
    }
    if (hasAny(const [
      '订阅已更新',
      'subscription changed',
      'subscription was updated',
    ])) {
      return AppErrorCode.subscriptionChanged;
    }
    if (hasAny(const ['订阅', 'subscription']) &&
        hasAny(const ['失败', 'failed', 'invalid', '无可用'])) {
      return AppErrorCode.subscriptionFailed;
    }
    if (hasAny(const ['配置', 'config', 'yaml']) &&
        hasAny(const ['失败', 'invalid', '无效', '验证'])) {
      return AppErrorCode.configInvalid;
    }
    if (hasAny(const ['update', '更新', '安装包']) &&
        hasAny(const ['failed', '失败', 'invalid', '校验'])) {
      return AppErrorCode.updateFailed;
    }
    if (hasAny(const ['mihomo', 'atlas', '核心']) &&
        hasAny(const ['not found', 'missing', '不存在', '缺失', '完整性'])) {
      return AppErrorCode.coreMissing;
    }
    if (hasAny(const ['timeout', 'timed out', '超时']) &&
        hasAny(const ['core', 'mihomo', 'atlas', '核心', '启动', 'start'])) {
      return AppErrorCode.coreStartTimeout;
    }
    if (hasAny(const ['mihomo api', '核心连接', 'core unavailable', '核心退出'])) {
      return AppErrorCode.coreUnavailable;
    }
    return AppErrorCode.unknown;
  }
}

enum AppDiagnosticStatus { passed, warning, failed, skipped }

enum AppRepairAction { retryOwnedProxyRecovery }

class AppDiagnosticCheck {
  const AppDiagnosticCheck({
    required this.id,
    required this.title,
    required this.status,
    required this.summary,
    this.errorCode,
    this.repairAction,
  });

  final String id;
  final String title;
  final AppDiagnosticStatus status;
  final String summary;
  final AppErrorCode? errorCode;
  final AppRepairAction? repairAction;
}

class AppDiagnosticReport {
  AppDiagnosticReport({
    required this.generatedAt,
    required List<AppDiagnosticCheck> checks,
    this.recentLogs = '',
  }) : checks = List.unmodifiable(checks);

  final DateTime generatedAt;
  final List<AppDiagnosticCheck> checks;
  final String recentLogs;

  bool get hasFailures =>
      checks.any((check) => check.status == AppDiagnosticStatus.failed);

  String toText({int maxLength = 8192}) {
    if (maxLength <= 0) throw ArgumentError.value(maxLength, 'maxLength');
    final buffer = StringBuffer()
      ..writeln('SSRVPN 诊断报告')
      ..writeln('生成时间: ${generatedAt.toUtc().toIso8601String()}');
    for (final check in checks) {
      final code = check.errorCode?.wireName;
      final title = _safeField(check.title);
      final summary = _safeField(check.summary);
      buffer.writeln(
        '[${check.status.name.toUpperCase()}] $title'
        '${code == null ? '' : ' ($code)'}: $summary',
      );
    }
    final logs = LogRedactor.sanitize(recentLogs).trim();
    if (logs.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('最近日志（已脱敏）:')
        ..writeln(logs);
    }
    final text = buffer.toString();
    if (text.length <= maxLength) return text;
    const marker = '\n…报告已截断';
    if (maxLength <= marker.length) return text.substring(0, maxLength);
    return '${text.substring(0, maxLength - marker.length)}$marker';
  }

  static String _safeField(String value) => LogRedactor.sanitize(
        value,
      ).replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
}

class AppRepairResult {
  const AppRepairResult({required this.success, required this.message});

  final bool success;
  final String message;
}
