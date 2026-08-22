import '../utils/log_redactor.dart';

enum AppErrorCode {
  coreMissing('CORE_MISSING'),
  coreStartTimeout('CORE_START_TIMEOUT'),
  coreUnavailable('CORE_UNAVAILABLE'),
  localProxyUnavailable('LOCAL_PROXY_UNAVAILABLE'),
  dataPlaneDegraded('DATA_PLANE_DEGRADED'),
  appLocationRequired('APP_LOCATION_REQUIRED'),
  networkConflict('NETWORK_CONFLICT'),
  systemProxyChanged('SYSTEM_PROXY_CHANGED'),
  systemProxyOwnershipUnavailable('SYSTEM_PROXY_OWNERSHIP_UNAVAILABLE'),
  tunRecoveryPending('TUN_RECOVERY_PENDING'),
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
    final isTunRuntimeFailure = text.contains('tun 监听未能启用') ||
        text.contains('tun_runtime_unavailable') ||
        text.contains('tun_config_mismatch');
    final requiresAdministratorAccount = text.contains('管理员账户');
    final requiresAdministratorRelaunch = !isTunRuntimeFailure &&
        (text.contains('以管理员身份运行') || text.contains('管理员权限'));
    final requiresNetworkRestart = text.contains('tun 网卡或路由创建失败');
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
      AppErrorCode.localProxyUnavailable => const AppFailure(
          code: AppErrorCode.localProxyUnavailable,
          title: '本地代理未就绪',
          message: '运行核心已启动，但系统代理使用的本地监听尚未就绪。',
          recommendedAction: '请重新连接；若持续失败，请关闭占用本地代理端口的程序后重试。',
        ),
      AppErrorCode.dataPlaneDegraded => const AppFailure(
          code: AppErrorCode.dataPlaneDegraded,
          title: '连接质量提示',
          message: '核心与系统网络接管仍在运行，但当前验证站点暂时不可达。',
          recommendedAction: '如界面已显示连接，当前连接仍保留；若实际无法上网，请稍后重试或手动切换节点。',
        ),
      AppErrorCode.appLocationRequired => const AppFailure(
          code: AppErrorCode.appLocationRequired,
          title: '需要先安装应用',
          message: 'macOS 的 TUN 模式只能从“应用程序”文件夹安全启动。',
          recommendedAction: '请将 SSRVPN 拖入 Applications（应用程序）文件夹，重新打开后再连接。',
        ),
      AppErrorCode.networkConflict => AppFailure(
          code: AppErrorCode.networkConflict,
          title: '网络环境冲突',
          message: '检测到其他 VPN/TUN 正在接管网络，或连接期间网络发生了切换。',
          recommendedAction: requiresNetworkRestart
              ? '请重启电脑后重新连接。'
              : '请先断开其他 VPN，确认当前网络稳定后重新连接。',
        ),
      AppErrorCode.systemProxyChanged => const AppFailure(
          code: AppErrorCode.systemProxyChanged,
          title: '系统代理已被修改',
          message: 'SSRVPN 设置的系统代理被其他程序关闭或替换。',
          recommendedAction: '请关闭其他代理或 VPN 后重新连接。',
        ),
      AppErrorCode.systemProxyOwnershipUnavailable => const AppFailure(
          code: AppErrorCode.systemProxyOwnershipUnavailable,
          title: '系统代理状态暂不可确认',
          message: '应用暂时无法读取系统代理所有权状态，当前连接未因此中断。',
          recommendedAction: '可稍后重新运行诊断；若实际无法上网，再检查其他代理或 VPN。',
        ),
      AppErrorCode.tunRecoveryPending => const AppFailure(
          code: AppErrorCode.tunRecoveryPending,
          title: 'TUN 网络待恢复',
          message: '上一次 TUN 的网卡、路由或 DNS 尚未确认清理完成。',
          recommendedAction: '请保持 SSRVPN 打开并再次点击连接完成恢复；若持续失败，请重启电脑后重试。',
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
          recommendedAction: isTunRuntimeFailure
              ? '请重新授权并关闭其他 VPN；仍失败请重启电脑，或重装官方版本后重试。'
              : requiresAdministratorAccount
                  ? '请退出 SSRVPN 后，登录管理员账户并重新运行。'
                  : requiresAdministratorRelaunch
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

    // Runtime health paths use stable, log-safe prefixes. Classify them before
    // localized detail text so callers do not lose an actionable category when
    // the accompanying explanation changes.
    if (text.contains('core_start_permission')) {
      return AppErrorCode.permissionRequired;
    }
    if (text.contains('core_start_port_conflict')) {
      return AppErrorCode.portOccupied;
    }
    if (hasAny(const ['core_start_api_auth', 'core_start_tun'])) {
      return AppErrorCode.coreUnavailable;
    }
    if (text.contains('core_start_config')) {
      return AppErrorCode.configInvalid;
    }
    if (text.contains('core_start_timeout')) {
      return AppErrorCode.coreStartTimeout;
    }
    if (text.contains('core_start_component')) {
      return AppErrorCode.coreMissing;
    }
    if (text.contains('core_start_busy')) {
      return AppErrorCode.coreUnavailable;
    }
    if (text.contains('core_start_unknown')) return AppErrorCode.unknown;
    if (hasAny(const ['tun_runtime_unavailable', 'tun_config_mismatch'])) {
      return AppErrorCode.permissionRequired;
    }
    if (hasAny(const [
      'local_proxy_listener_unavailable',
      'local_proxy_config_mismatch',
    ])) {
      return AppErrorCode.localProxyUnavailable;
    }
    if (text.contains('system_proxy_ownership_unavailable')) {
      return AppErrorCode.systemProxyOwnershipUnavailable;
    }
    if (text.contains('system_proxy_ownership_lost')) {
      return AppErrorCode.systemProxyChanged;
    }
    if (hasAny(const ['core_api_unavailable', 'tun_service_lost'])) {
      return AppErrorCode.coreUnavailable;
    }
    if (text.contains('applications 文件夹')) {
      return AppErrorCode.appLocationRequired;
    }
    if (hasAny(const [
      '找不到 mihomo.exe',
      '找不到核心文件',
      '核心资产尚未通过安全准备',
      'windows 架构不兼容',
      '32/64 位架构不匹配',
      'not a valid win32',
      'tun 授权组件缺失',
      'tun 核心资源缺失',
      'tun dns 恢复组件缺失',
      'tun 授权组件启动失败',
    ])) {
      return AppErrorCode.coreMissing;
    }
    // Explicit permission failures can also mention a possible adapter
    // conflict. Preserve the actionable administrator guidance in that case.
    if (hasAny(const [
      'access is denied',
      'permission denied',
      'administrator required',
      '权限不足',
      '执行权限',
      '需要管理员',
      '需要授权',
      '授权失败',
      '管理员权限',
      '管理员授权',
      '管理员账户',
      '以管理员身份运行',
      '安全软件拦截',
    ])) {
      return AppErrorCode.permissionRequired;
    }
    if (hasAny(const [
      '其他 vpn/tun',
      '现有 vpn 路由状态',
      '物理网络已切换',
      'tun 网卡或路由创建失败',
      'tun dns 接管失败',
      '同名虚拟网卡冲突',
    ])) {
      return AppErrorCode.networkConflict;
    }
    if (hasAny(const [
      'tun dns 恢复',
      'tun dns 未能安全恢复',
      '未恢复的 tun dns',
      'dns 恢复标记',
      'tun 恢复标记',
      'tun 清理状态',
      'tun 网卡未在超时前移除',
      'tun 网卡和路由已清理',
      'tun 会话标记',
      '上次异常退出的 tun 会话',
      '特权会话标记',
      '死路由',
    ])) {
      return AppErrorCode.tunRecoveryPending;
    }
    if (hasAny(const [
      'tun 配置缺失',
      'tun 数据目录无效',
      'tun 配置校验超时',
    ])) {
      return AppErrorCode.configInvalid;
    }
    if (text.contains('找不到生成的 mihomo 配置文件')) {
      return AppErrorCode.configInvalid;
    }
    if (hasAny(const [
      '电脑性能不足或配置校验超时，请重新连接',
      '核心启动过慢',
    ])) {
      return AppErrorCode.coreStartTimeout;
    }
    if (hasAny(const [
      'mihomo 提前退出（退出码',
      'tun 核心启动失败',
      'mihomo 启动后未通过就绪检查',
      '连接提交前的就绪检查失败',
      'mihomo 在连接提交期间失去响应',
      'mihomo 在系统代理设置期间失去响应',
      'mihomo 在连接提交期间退出',
      'mihomo 在系统代理设置期间退出',
      'tun 启动最终复核失败',
      'tun 核心未能通过健康检查',
    ])) {
      return AppErrorCode.coreUnavailable;
    }
    if (hasAny(const [
          'address already in use',
          'port occupied',
          '端口被占用',
          '端口被其他程序占用',
        ]) ||
        (text.contains('bind') && text.contains('port'))) {
      return AppErrorCode.portOccupied;
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
