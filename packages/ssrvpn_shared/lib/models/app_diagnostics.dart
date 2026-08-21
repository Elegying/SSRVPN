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

const _trustedUserFacingFailureMessages = <String>{
  '客户端仍在初始化，请稍后重试',
  '请先添加并刷新订阅',
  '订阅已更新，请重新连接以使用最新配置',
  '托盘连接失败，请重试或查看日志',
  '无法安全断开当前连接，已阻止打开更新安装包',
};

String safeUserFacingFailureMessage(Object? error) {
  final text = error?.toString().trim() ?? '';
  var trustedText = text;
  if (error is StateError) {
    trustedText = error.message.toString().trim();
  }
  if (_trustedUserFacingFailureMessages.contains(trustedText)) {
    return trustedText;
  }
  return AppFailure.fromMessage(error).userMessage;
}

String safeUserFacingFailureWithAction(Object? error, String action) =>
    '${safeUserFacingFailureMessage(error)}\n${action.trim()}';

String safeSubscriptionFailureMessage(Object? error) =>
    safeUserFacingFailureMessage(error);

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

  String get userMessage => '$title：$message $recommendedAction';

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
          title: '连接质量提示',
          message: '核心与系统网络接管仍在运行，但当前验证站点暂时不可达。',
          recommendedAction: '如界面已显示连接，当前连接仍保留；若实际无法上网，请稍后重试或手动切换节点。',
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
          message: '节点或订阅配置未通过格式验证。',
          recommendedAction: '请检查节点名称、服务器、端口和认证信息，或刷新订阅后重试。',
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

    if (text.contains('找不到生成的 mihomo 配置文件')) {
      return AppErrorCode.configInvalid;
    }
    if (text.contains('电脑性能不足或配置校验超时，请重新连接')) {
      return AppErrorCode.coreStartTimeout;
    }
    if (hasAny(const [
      'mihomo 提前退出（退出码',
      'tun 核心启动失败',
      'mihomo 启动后未通过就绪检查',
    ])) {
      return AppErrorCode.coreUnavailable;
    }
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
      '授权失败',
      '管理员授权',
      '以管理员身份运行',
    ])) {
      return AppErrorCode.permissionRequired;
    }
    if (hasAny(const [
      '系统代理恢复失败',
      '代理待恢复',
      'proxy recovery',
      'restore proxy',
      '系统代理 powershell 命令响应超时',
      '系统代理命令响应超时',
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
    if ((hasAny(const ['订阅', 'subscription']) &&
            hasAny(const ['失败', 'failed', 'invalid', '无可用'])) ||
        hasAny(const ['请先添加并刷新订阅', '请先刷新订阅', '未获取到可用节点'])) {
      return AppErrorCode.subscriptionFailed;
    }
    if (hasAny(const [
      '节点备注名',
      '服务器地址无效',
      '端口必须是',
      '节点缺少',
      '没有可编辑的订阅配置',
      '找不到要修改的节点',
      '订阅配置中没有有效的节点列表',
      '修改后的订阅不包含可运行节点',
      '字段清理后名称冲突',
      '运行时保留名称',
    ])) {
      return AppErrorCode.configInvalid;
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
    if (hasAny(const [
      'mihomo service is not initialized',
      'core is not initialized',
      '核心未初始化',
      '连接服务尚未初始化',
      '客户端仍在初始化',
      '无法启动核心',
    ])) {
      return AppErrorCode.coreUnavailable;
    }
    if (hasAny(const [
      'data plane',
      'data-plane',
      '数据通道',
      '网络验证失败',
    ])) {
      return AppErrorCode.dataPlaneDegraded;
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
    final logs = LogRedactor.sanitizeForDisplay(recentLogs).trim();
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

  static String _safeField(String value) => LogRedactor.sanitizeForDisplay(
        value,
      ).replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
}

class AppRepairResult {
  const AppRepairResult({required this.success, required this.message});

  final bool success;
  final String message;
}
