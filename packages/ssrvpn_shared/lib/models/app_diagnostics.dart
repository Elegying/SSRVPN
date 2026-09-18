import 'package:flutter/foundation.dart';

import '../constants/app_constants.dart';
import '../utils/log_redactor.dart';
import '../services/subscription_failure_diagnosis.dart';

enum AppErrorCode {
  coreMissing('CORE_MISSING'),
  coreStartTimeout('CORE_START_TIMEOUT'),
  coreUnavailable('CORE_UNAVAILABLE'),
  localProxyUnavailable('LOCAL_PROXY_UNAVAILABLE'),
  dataPlaneDegraded('DATA_PLANE_DEGRADED'),
  appLocationRequired('APP_LOCATION_REQUIRED'),
  networkConflict('NETWORK_CONFLICT'),
  networkUnavailable('NETWORK_UNAVAILABLE'),
  networkTimeout('NETWORK_TIMEOUT'),
  secureConnectionFailed('SECURE_CONNECTION_FAILED'),
  systemProxyApplyFailed('SYSTEM_PROXY_APPLY_FAILED'),
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
  '首选节点恢复失败，请恢复存储权限后重试；订阅恢复记录已保留',
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

String safeSubscriptionFailureMessage(Object? error) {
  final diagnosis =
      SubscriptionFailureDiagnosis.fromError(error ?? StateError('missing'));
  return diagnosis.code == 'SUB_UNKNOWN'
      ? safeUserFacingFailureMessage(error)
      : diagnosis.summary;
}

class AppFailure {
  const AppFailure({
    required this.code,
    required this.title,
    required this.message,
    required this.recommendedAction,
    this.summary,
  });

  final AppErrorCode code;
  final String title;
  final String message;
  final String recommendedAction;
  final String? summary;

  String get userMessage =>
      summary ??
      switch (code) {
        AppErrorCode.coreMissing => '连接服务文件不完整，请重新安装官方客户端。',
        AppErrorCode.coreStartTimeout => '连接服务启动时间过长，请稍后重新连接。',
        AppErrorCode.coreUnavailable => '暂时无法与连接服务正常通信，请运行诊断确认状态。',
        AppErrorCode.localProxyUnavailable => '本地连接服务尚未准备好，请稍后重新连接。',
        AppErrorCode.dataPlaneDegraded => '暂未确认能否正常上网，请打开网页检查实际使用情况。',
        AppErrorCode.networkTimeout => '服务器未能及时响应，请检查网络或稍后重试。',
        AppErrorCode.networkUnavailable => '暂时无法联系目标服务器，请检查网络或稍后重试。',
        AppErrorCode.secureConnectionFailed => '无法建立可信的加密连接，请检查设备时间或联系服务提供方。',
        AppErrorCode.portOccupied => '连接所需的本地端口被占用，请关闭冲突程序或更改代理端口。',
        AppErrorCode.configInvalid => '配置无法使用，请检查节点名称、服务器、端口和认证信息。',
        AppErrorCode.subscriptionFailed => '订阅刷新失败，请确认链接或稍后重试。',
        AppErrorCode.unknown => '操作未完成，暂时无法确定具体原因，请重试或复制诊断报告。',
        AppErrorCode.updateFailed => '更新失败，当前版本仍可使用，请稍后重试。',
        AppErrorCode.proxyRecoveryPending => '系统代理待恢复，请保持断开并点击修复系统代理。',
        AppErrorCode.appLocationRequired => '请先把客户端移到“应用程序”文件夹，再打开并连接。',
        AppErrorCode.networkConflict => '网络连接存在冲突，请关闭其他 VPN 并确认网络稳定后重试。',
        AppErrorCode.systemProxyApplyFailed => '系统未能应用连接设置，请检查其他代理软件后重试。',
        AppErrorCode.systemProxyChanged => '系统连接设置已被修改，请确认是否正在使用其他代理软件。',
        AppErrorCode.systemProxyOwnershipUnavailable =>
          '暂时无法读取系统连接设置，请运行诊断确认状态。',
        AppErrorCode.tunRecoveryPending =>
          '尚未确认上次连接的网络设置已恢复，请稍后再次连接；持续失败请查看诊断。',
        AppErrorCode.permissionRequired => recommendedAction,
        AppErrorCode.subscriptionPartial => '部分订阅未能更新，原有可用数据已保留，请查看失败详情。',
        AppErrorCode.subscriptionChanged => '订阅已发生变化，请重新连接以使用最新节点。',
      };

  static AppFailure fromMessage(Object? error) {
    final text = error?.toString().trim().toLowerCase() ?? '';
    if (text.contains('分流规则尚未就绪')) {
      return const AppFailure(
        code: AppErrorCode.coreStartTimeout,
        title: '分流规则仍未就绪',
        summary: '等待连接时，分流规则仍未准备好，请稍后重新连接。',
        message: '核心已响应，但检查时分流规则尚未全部就绪，暂不能判断规则文件损坏。',
        recommendedAction: '请稍后重新连接；若持续出现，请复制诊断报告以检查加载过程。',
      );
    }
    if (text.contains('tun_rule_files:')) {
      return const AppFailure(
        code: AppErrorCode.configInvalid,
        title: '分流规则未就绪',
        summary: '本次连接的分流规则未能加载，请重新连接或复制诊断报告。',
        message: '本次连接所需的分流规则文件未能完整加载。',
        recommendedAction: '请重新连接；若仍然失败，请导出运行日志以定位缺失的规则文件。',
      );
    }
    if (text.contains('vpn_permission_denied') ||
        text.contains('用户拒绝了 vpn 权限')) {
      return const AppFailure(
        code: AppErrorCode.permissionRequired,
        title: '尚未允许 VPN 连接',
        summary: '尚未获得系统连接许可，请重新连接并在弹窗中选择允许。',
        message: '系统 VPN 授权未通过，本次连接没有建立。',
        recommendedAction: '请再次点击连接，在系统“网络连接请求”中选择允许或确定。',
      );
    }
    if (text.contains('取消了管理员授权')) {
      return const AppFailure(
        code: AppErrorCode.permissionRequired,
        title: '已取消 TUN 授权',
        summary: '连接已取消，重新连接时请在系统弹窗中完成授权。',
        message: '管理员验证未完成，本次 TUN 连接没有启动。',
        recommendedAction: '需要使用 TUN 时，请再次连接并在系统窗口完成管理员验证。',
      );
    }
    if (text.contains('core_start_api_auth')) {
      return const AppFailure(
        code: AppErrorCode.coreUnavailable,
        title: '本地控制服务认证失败',
        summary: '客户端与连接服务的信息不一致，请退出并重新打开客户端。',
        message: '应用与本地 VPN 服务的连接信息不一致。',
        recommendedAction: '请退出并重新打开 SSRVPN 后重试；仍失败请查看诊断中的核心状态。',
      );
    }
    if (text.contains('core_start_tun')) {
      return const AppFailure(
        code: AppErrorCode.coreUnavailable,
        title: '系统 VPN 接口未能就绪',
        summary: '系统连接服务未准备好，请确认授权并关闭其他 VPN 后重试。',
        message: 'VPN 接口或网络保护组件未能完成初始化。',
        recommendedAction: '请确认已允许 VPN，断开其他 VPN 后重新连接；仍失败请重启应用。',
      );
    }
    if (text.contains('core_start_busy')) {
      return const AppFailure(
        code: AppErrorCode.coreUnavailable,
        title: '上一项连接操作尚未结束',
        summary: '上一项连接操作还未结束，请稍候再试。',
        message: 'VPN 服务仍在启动或清理上一条连接。',
        recommendedAction: '请等待几秒后再次连接；若一直无法完成，请查看诊断中的核心状态。',
      );
    }
    if (text.contains('system_proxy_settle_timeout')) {
      return const AppFailure(
        code: AppErrorCode.systemProxyApplyFailed,
        title: '系统代理尚未确认生效',
        summary: '系统尚未确认连接设置生效，请等待网络稳定后重新连接。',
        message: '代理设置已提交，但 macOS 当前网络未能及时确认使用该设置。',
        recommendedAction: '请确认当前网络稳定后重新连接；若反复发生，请检查其他代理软件并运行诊断。',
      );
    }
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
          message: '设备上的 VPN 服务未能在限定时间内完成启动。',
          recommendedAction: '请重新连接；若反复发生，请重启应用，再运行诊断检查核心状态。',
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
      AppErrorCode.networkUnavailable => AppFailure(
          code: AppErrorCode.networkUnavailable,
          summary: text.contains('failed host lookup') ||
                  text.contains('地址解析失败')
              ? '暂时找不到服务器地址，请检查网络或稍后重试。'
              : text.contains('connection refused') || text.contains('目标服务拒绝')
                  ? '目标服务器拒绝了本次连接，请稍后重试或联系服务提供方。'
                  : null,
          title: text.contains('connection refused') || text.contains('目标服务拒绝')
              ? '目标服务拒绝连接'
              : text.contains('failed host lookup') || text.contains('地址解析失败')
                  ? '服务器地址解析失败'
                  : '网络连接未建立',
          message: text.contains('connection refused') ||
                  text.contains('目标服务拒绝')
              ? '目标地址的服务端口拒绝了本次连接。'
              : text.contains('failed host lookup') || text.contains('地址解析失败')
                  ? '当前网络未能把服务器域名解析为可连接的地址。'
                  : '当前网络无法与目标服务建立连接。',
          recommendedAction: '请先确认普通网页能够打开，再刷新订阅或切换节点；仍失败请联系节点提供方。',
        ),
      AppErrorCode.networkTimeout => const AppFailure(
          code: AppErrorCode.networkTimeout,
          title: '等待服务器响应超时',
          message: '目标服务未在限定时间内响应，网络或节点可能暂时不可达。',
          recommendedAction: '请先确认网络可用，再重试或切换节点。',
        ),
      AppErrorCode.secureConnectionFailed => const AppFailure(
          code: AppErrorCode.secureConnectionFailed,
          title: '安全连接校验失败',
          message: '无法完成加密连接或验证服务器证书。',
          recommendedAction: '请确认设备日期和时间正确，再更新订阅或切换网络重试。',
        ),
      AppErrorCode.systemProxyApplyFailed => const AppFailure(
          code: AppErrorCode.systemProxyApplyFailed,
          title: '系统代理未能启用',
          message: '运行核心已启动，但系统未能把本地代理应用到当前网络服务。',
          recommendedAction: '请使用管理员账户，关闭其他代理或 VPN 后重试；若持续失败，请复制诊断报告。',
        ),
      AppErrorCode.systemProxyChanged => const AppFailure(
          code: AppErrorCode.systemProxyChanged,
          title: '系统代理已被修改',
          message: '当前系统代理设置与 SSRVPN 本次连接不一致，可能已被手动或其他程序修改。',
          recommendedAction: '请确认需要使用哪个代理，关闭其他代理或 VPN 后重新连接。',
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
          message: 'VPN 服务需要的本地监听端口正在被其他程序使用。',
          recommendedAction: '请关闭占用端口的程序后重试；再次连接时会尝试选择可用端口。',
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
          message: '暂时无法确定具体原因。',
          recommendedAction: '请重试；若仍失败，运行诊断查看检查结果，并复制报告反馈。',
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
    if (text.contains('system_proxy_ownership_lost')) {
      return AppErrorCode.systemProxyChanged;
    }
    if (text.contains('system_proxy_apply_failed')) {
      return AppErrorCode.systemProxyApplyFailed;
    }
    if (text.contains('system_proxy_ownership_unavailable')) {
      return AppErrorCode.systemProxyOwnershipUnavailable;
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
    if (hasAny(const [
      'handshakeexception',
      'certificate_verify_failed',
      'certificate verify failed',
      'tls handshake',
      '安全连接校验失败',
    ])) {
      return AppErrorCode.secureConnectionFailed;
    }
    if (hasAny(const ['timeoutexception', 'timed out', 'timeout', '超时']) &&
        hasAny(const [
          'socketexception',
          'httpexception',
          'network request',
          'http request',
          'request timed out',
          'request timeout',
          '网络请求',
          '网络连接',
          '连接超时',
          '服务器响应',
        ])) {
      return AppErrorCode.networkTimeout;
    }
    if (hasAny(const [
      'socketexception',
      'connection refused',
      'failed host lookup',
      'network is unreachable',
      'no route to host',
      '目标服务拒绝',
      '地址解析失败',
      '网络连接未建立',
    ])) {
      return AppErrorCode.networkUnavailable;
    }
    return AppErrorCode.unknown;
  }
}

enum AppDiagnosticStatus { passed, warning, failed, skipped }

enum AppRepairAction { retryOwnedProxyRecovery }

enum AppDiagnosticLogLevel { information, warning, error }

class AppDiagnosticLogEntry {
  const AppDiagnosticLogEntry({
    required this.timeLabel,
    required this.level,
    required this.category,
    required this.message,
    this.technicalDetail,
  });

  final String timeLabel;
  final AppDiagnosticLogLevel level;
  final String category;
  final String message;
  final String? technicalDetail;

  String get levelLabel => switch (level) {
        AppDiagnosticLogLevel.information => '信息',
        AppDiagnosticLogLevel.warning => '提醒',
        AppDiagnosticLogLevel.error => '错误',
      };

  bool get requiresAttention => level != AppDiagnosticLogLevel.information;
}

List<AppDiagnosticLogEntry> readableDiagnosticLogs(
  String rawLogs, {
  int maxEntries = 20,
}) {
  if (maxEntries <= 0) throw ArgumentError.value(maxEntries, 'maxEntries');
  final sanitized = LogRedactor.sanitizeForDisplay(rawLogs);
  final pattern = RegExp(
    r'^\[([^\]]+)\] \[([^\]]+)\] \[([^\]]+)\] '
    r'(?:\[session=[^\]]+\] )?(.*)$',
  );
  final entries = <AppDiagnosticLogEntry>[];
  final seen = <String>{};
  for (final rawLine in sanitized.split(RegExp(r'[\r\n]+'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final match = pattern.firstMatch(line);
    final rawMessage = match?.group(4) ?? line;
    final message = _plainRuntimeSummary(match?.group(3), rawMessage) ??
        _readableDiagnosticMessage(rawMessage);
    if (message == null || message.isEmpty) continue;
    final coreLevel = match?.group(3) == 'runtime'
        ? RegExp(r'^\[mihomo\] time="[^"]+" level=(warning|error|fatal) msg=')
            .firstMatch(rawMessage)
            ?.group(1)
        : null;
    final level = switch (match?.group(2)?.toUpperCase()) {
      'WARNING' || 'WARN' => AppDiagnosticLogLevel.warning,
      'ERROR' || 'SEVERE' => AppDiagnosticLogLevel.error,
      _ => switch (coreLevel) {
          'error' || 'fatal' => AppDiagnosticLogLevel.error,
          'warning' => AppDiagnosticLogLevel.warning,
          _ => AppDiagnosticLogLevel.information,
        },
    };
    final category = _readableDiagnosticCategory(match?.group(3));
    // Different evidence can share a plain-language summary. Only collapse
    // genuinely repeated observations, not distinct causes or endpoints.
    final deduplicationKey = '${level.name}|$category|$message|$rawMessage';
    if (!seen.add(deduplicationKey)) continue;
    entries.add(
      AppDiagnosticLogEntry(
        timeLabel: _readableDiagnosticTime(match?.group(1)),
        level: level,
        category: category,
        message: message,
        technicalDetail: message == rawMessage ? null : rawMessage,
      ),
    );
    if (entries.length == maxEntries) break;
  }
  return List.unmodifiable(entries);
}

// Match owned event categories and explicit observations, never guess a cause
// from arbitrary core output. Raw evidence remains available in the report.
String? _plainRuntimeSummary(String? event, String text) {
  if (event == 'runtime' &&
      RegExp(r'^\[mihomo\] time="[^"]+" level=warning msg="\[SSRVPN_IPV6_TARGET_FAILED\] ')
          .hasMatch(text)) {
    return '这次未能访问 IPv6 目标，可能是本地网络或节点无法到达；直连目标请检查本机 IPv6 网络，代理目标可换节点重试，其他连接保持不变。';
  }

  if (event == 'runtime' &&
      RegExp(r'^\[mihomo\] time="[^"]+" level=(warning|error) msg="\[TCP\] dial DIRECT ')
          .hasMatch(text) &&
      text.contains('bind6:')) {
    return '这次直连请求无法使用本机的 IPv6 出口；请检查正在联网的网卡是否启用 IPv6，换代理节点不能解决这类直连错误。';
  }

  // This exact core error identifies a failed TCP connection to the proxy
  // server. A generic website timeout does not establish the same cause.
  if (event == 'runtime' &&
      RegExp(r'^\[mihomo\] time="[^"]+" level=(warning|error) msg="\[TCP\] dial ')
          .hasMatch(text) &&
      !text.contains('msg="[TCP] dial DIRECT ') &&
      text.contains(' connect error: ') &&
      RegExp(r'dial tcp [^"\r\n]+: i/o timeout').hasMatch(text)) {
    return '这次未能连上节点服务器，请稍后重试或换个节点。';
  }
  if (event == 'runtime' &&
      RegExp(r'\b(?:CORE_START_[A-Z_]+|CORE_API_UNAVAILABLE|TUN_RULE_FILES|VPN_PERMISSION_DENIED)\b')
          .hasMatch(text)) {
    return AppFailure.fromMessage(text).userMessage;
  }
  if (event == 'subscription_refresh') {
    return text.replaceFirst(RegExp(r' \[SUB_[A-Z0-9_]+\]$'), '');
  }
  if (event == 'health_check') {
    return '暂时无法确认连接状态，正在复查。';
  }
  if (event == 'health_recovery_wait') {
    return '连接状态暂时未通过检查，先保留连接并等待恢复。';
  }
  if (event == 'health_recovered') {
    return '连接状态已恢复正常，本次没有重启连接。';
  }
  if (event == 'health_recovery') {
    if (text.contains('连接运行状态已自动恢复')) return '连接已自动恢复。';
    if (text.contains('运行状态持续异常')) return '连接状态持续异常，正在尝试恢复。';
    if (text.contains('恢复失败')) return '自动恢复未完成，请运行诊断确认连接状态。';
  }
  if (event == 'data_plane_probe') {
    if (text.contains('未通过')) return '暂未确认能否正常上网，当前连接仍保持。';
    if (text.contains('已恢复')) return '已重新确认可以访问外部网络。';
  }
  if (event == 'rule_provider_refresh' && text.contains('失败')) {
    return '本次规则更新未完成，继续使用原有规则。';
  }
  if (event == 'latency_probe_failed') {
    return '这次未能测出节点延迟，暂时无法判断节点是否可用。';
  }
  return null;
}

String _readableDiagnosticCategory(String? event) => switch (event) {
      'rule_provider_baseline' || 'rule_provider_refresh' => '智能规则',
      'data_plane_probe' => '网络检查',
      'health_check' ||
      'health_recovery' ||
      'health_recovery_wait' ||
      'health_recovered' =>
        '连接恢复',
      'latency_probe_failed' || 'latency_result' => '节点测速',
      'system_proxy_health' => '系统代理',
      'proxy_switch' => '节点切换',
      'connection_cleanup' => '断开连接',
      'tun_recovery' => '网络恢复',
      'subscription_refresh' => '订阅更新',
      'runtime' => '连接',
      _ => '运行记录',
    };

String _readableDiagnosticTime(String? value) {
  final parsed = value == null ? null : DateTime.tryParse(value);
  if (parsed == null) return '时间未记录';
  final local = parsed.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String? _readableDiagnosticMessage(String? rawMessage) {
  if (rawMessage == null) return null;
  var message = rawMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (message.isEmpty) return null;
  const hiddenInventoryPrefixes = [
    '核心文件大小:',
    '核心架构:',
    '核心版本:',
    '系统:',
    '程序路径:',
    '配置目录:',
    '核心路径:',
    '诊断日志:',
  ];
  if (hiddenInventoryPrefixes.any(message.startsWith)) return null;
  if (message.startsWith('正在校验 Mihomo 配置')) return null;
  if (message.startsWith('[配置校验]') && message.contains('test is successful')) {
    return null;
  }
  const providerNames = {
    'ssrvpn-user-feedback-rules': '用户反馈规则',
    'ssrvpn-ai-services': 'AI 服务规则',
    'ssrvpn-foreign-services': '海外服务规则',
    'ssrvpn-streaming-services': '流媒体规则',
    'ssrvpn-china-domains': '国内服务规则',
    'ssrvpn-company-asn': '国内企业网络规则',
  };
  for (final entry in providerNames.entries) {
    message = message.replaceAll(entry.key, entry.value);
  }
  message = message.replaceFirstMapped(
    RegExp(r'^智能规则基线 ([0-9.]+) 已就绪：.*$'),
    (match) => '内置智能规则 ${match.group(1)} 已就绪',
  );
  message = message.replaceFirstMapped(
    RegExp(r'^规则集已检查更新: (.+)$'),
    (match) => '${match.group(1)}已更新',
  );
  if (message.length > 180) return '${message.substring(0, 179)}…';
  return message;
}

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

  List<AppDiagnosticLogEntry> get readableLogs =>
      readableDiagnosticLogs(recentLogs);

  String get userConclusion {
    final failureCount = checks
        .where((check) => check.status == AppDiagnosticStatus.failed)
        .length;
    if (failureCount > 0) return '发现 $failureCount 项需要处理的问题';
    final warningCount = checks
        .where((check) => check.status == AppDiagnosticStatus.warning)
        .length;
    if (warningCount > 0) return '检查完成，发现 $warningCount 项提醒';
    final logAttentionCount =
        readableLogs.where((entry) => entry.requiresAttention).length;
    if (logAttentionCount > 0) {
      return '当前检查正常，最近有 $logAttentionCount 条提醒';
    }
    if (checks.any((check) =>
        check.id == 'runtime' && check.status == AppDiagnosticStatus.skipped)) {
      return '本地检查通过，连接尚未验证';
    }
    return '运行正常，未发现异常';
  }

  String toText({int maxLength = 8192}) {
    if (maxLength <= 0) throw ArgumentError.value(maxLength, 'maxLength');
    final localTime = generatedAt.toLocal().toIso8601String();
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      _ => defaultTargetPlatform.name,
    };
    final buffer = StringBuffer()
      ..writeln('SSRVPN 诊断报告')
      ..writeln('客户端版本：${AppConstants.appVersion}')
      ..writeln('客户端平台：$platform')
      ..writeln('生成时间（本地）：$localTime')
      ..writeln('结论：$userConclusion')
      ..writeln()
      ..writeln('检查结果');
    for (final check in checks) {
      final code = check.errorCode?.wireName;
      final title = _safeField(check.title);
      final summary = _safeField(check.summary);
      final status = switch (check.status) {
        AppDiagnosticStatus.passed => '正常',
        AppDiagnosticStatus.warning => '提醒',
        AppDiagnosticStatus.failed => '需要处理',
        AppDiagnosticStatus.skipped => '未检查',
      };
      buffer.writeln(
        '- $status｜$title：$summary'
        '${code == null ? '' : '（错误编号：$code）'}',
      );
    }
    final logs = readableLogs;
    if (logs.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('最近运行记录（已整理、已脱敏）');
      for (final entry in logs) {
        buffer.writeln(
          '- ${entry.timeLabel}｜${entry.levelLabel}｜${entry.category}：'
          '${entry.message}',
        );
        if (entry.technicalDetail != null) {
          buffer.writeln('  技术详情：${_safeField(entry.technicalDetail!)}');
        }
      }
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
