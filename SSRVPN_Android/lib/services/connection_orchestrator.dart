import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../services/clash_service.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';

class AndroidConnectionOutcome {
  const AndroidConnectionOutcome({
    this.message,
    this.preferredNodeSwitchSucceeded = true,
    this.runtimeNodeName,
  });

  final String? message;
  final bool preferredNodeSwitchSucceeded;
  final String? runtimeNodeName;
}

({String? errorMessage, String? connectionNotice})
    resolveAndroidConnectionFeedback({
  required bool connected,
  required String? result,
  required String? runtimeNotice,
}) {
  final outcomeMessage = result?.trim();
  final noticeMessage = runtimeNotice?.trim();
  if (connected) {
    return (
      errorMessage: null,
      connectionNotice: outcomeMessage?.isNotEmpty == true
          ? outcomeMessage
          : noticeMessage?.isNotEmpty == true
              ? noticeMessage
              : null,
    );
  }
  return (
    errorMessage: userFriendlyAndroidConnectionError(
      outcomeMessage?.isNotEmpty == true ? outcomeMessage : null,
    ),
    connectionNotice: null,
  );
}

String userFriendlyAndroidConnectionError(Object? error) {
  final raw = error?.toString().trim() ?? '';
  final lower = raw.toLowerCase();

  if (raw == '请先添加并刷新订阅' || raw.startsWith('订阅已更新')) {
    return raw;
  }
  if (raw.contains('Missing required arguments') ||
      raw.contains('连接参数不完整') ||
      lower.contains('invalid_args')) {
    return '连接参数不完整，请重试';
  }
  if (raw.contains('VPN establish failed') || raw.contains('创建 VPN 接口')) {
    return '系统未能创建 VPN 接口，请检查 VPN 权限后重试';
  }
  if (lower.contains('core_start_port_conflict')) {
    return '本地代理端口被占用，请关闭占用端口的应用后重试';
  }
  if (lower.contains('core_start_api_auth')) {
    return '本地控制凭据不可用或与运行配置不一致，请重启应用后重试';
  }
  if (lower.contains('core_start_permission')) {
    return 'VPN 核心缺少必要权限，请检查系统设置后重试';
  }
  if (lower.contains('core_start_tun')) {
    return 'VPN 网络保护服务异常，请重新连接';
  }
  if (lower.contains('core_start_config')) {
    return 'VPN 配置不可用，请刷新订阅后重试';
  }
  if (lower.contains('core_start_timeout')) {
    return 'VPN 核心启动超时，请重新连接';
  }
  if (lower.contains('core_start_component')) {
    return 'VPN 核心组件不可用，请重新安装官方版本';
  }
  if (lower.contains('core_start_busy')) {
    return 'VPN 核心正在启动或清理，请稍后重试';
  }
  if (lower.contains('local api') ||
      raw.contains('本地控制服务') ||
      raw.contains('Health check timeout')) {
    return 'VPN 核心已启动，但本地控制服务未及时就绪，请重新连接';
  }
  if (lower.contains('bridge.start') ||
      lower.contains('core start timeout') ||
      raw.contains('核心启动超时') ||
      raw.contains('设备性能不足')) {
    return 'VPN 核心启动超时，请重新连接';
  }
  if (lower.contains('core_timeout') || raw.contains('VPN 启动超时')) {
    return 'VPN 启动超时，请重新连接；若持续失败请打开诊断与运行日志';
  }
  if (raw.contains('用户拒绝了 VPN 权限') || lower.contains('permission_denied')) {
    return '未获得 VPN 权限，请允许后重试';
  }
  if (lower.contains('stop_incomplete') || raw.contains('正在释放系统资源')) {
    return 'VPN 正在释放系统资源，请稍后重试';
  }
  if (lower.contains('stop_failed') || raw.contains('VPN 断开失败')) {
    return 'VPN 断开失败，请重试；若持续失败请打开诊断与运行日志';
  }
  if (lower.contains('core_busy') ||
      raw.contains('核心正在启动') ||
      raw.contains('核心正在清理')) {
    return 'VPN 核心正在启动或清理，请稍后重试';
  }
  if (raw.contains('VPN 网络保护服务启动失败') || raw.contains('VPN 网络保护服务异常')) {
    return 'VPN 网络保护服务异常，请重新连接';
  }
  if (raw.contains('VPN 凭据不可用')) {
    return 'VPN 凭据不可用，请打开应用重新连接';
  }
  if (raw.contains('VPN 配置不可用')) {
    return 'VPN 配置不可用，请打开应用重新连接';
  }
  if (raw.contains('无法保存连接恢复信息')) {
    return '无法保存连接恢复信息，VPN 已安全回滚，请重试';
  }
  if (raw.contains('Mihomo 原生组件不可用')) {
    return 'VPN 原生组件不可用，请重新安装应用';
  }
  if (raw.contains('连接已取消')) return '连接已取消';
  if (raw.contains('连接已中断')) return '连接已中断，请重新连接';
  if (lower.contains('timeoutexception') || lower.contains('timeout')) {
    return '连接超时，请检查网络后重试';
  }
  if (lower.contains('handshakeexception') ||
      lower.contains('certificate') ||
      lower.contains('tls')) {
    return '安全连接失败，请检查网络环境';
  }
  if (lower.contains('socketexception') ||
      lower.contains('connection refused') ||
      lower.contains('network')) {
    return '网络连接失败，请检查网络设置';
  }
  if (lower.contains('httpexception')) {
    return '服务器响应异常，请稍后重试';
  }
  return 'VPN 启动失败，请重试；若持续失败请打开诊断与运行日志';
}

/// Clears only the still-current connection intent owned by a failed attempt.
///
/// A newer connect/disconnect request must never be overwritten, and a core
/// that is still running keeps its desired intent for recovery.
bool rollbackFailedAndroidConnectionIntent(
  ClashService clashService,
  int? connectionGeneration,
) {
  if (connectionGeneration == null || clashService.isRunning) return false;
  if (!clashService.isConnectionIntentCurrent(
    connectionGeneration,
    connected: true,
  )) {
    return false;
  }
  clashService.requestConnectionIntent(false);
  return true;
}

/// 连接编排器
///
/// 抽取 home_screen 中 generateClashConfig + writeConfig + start +
/// updateVpnNotification + verify 的完整编排流程。
class ConnectionOrchestrator {
  final ClashService clashService;
  final SettingsService settingsService;
  final SubscriptionService subscriptionService;

  ConnectionOrchestrator({
    required this.clashService,
    required this.settingsService,
    required this.subscriptionService,
  });

  /// 执行连接流程
  ///
  /// [nodeName] 可选的首选节点名，null 则自动选择。
  /// 调用方仍以 [clashService.isRunning] 判断连接状态。结果将启动提示
  /// 与首选节点切换状态分开，避免把未成功切换的请求节点记为当前节点。
  Future<AndroidConnectionOutcome> connect(
    String? nodeName, {
    required int connectionGeneration,
  }) async {
    await settingsService.waitForPendingWrites();
    if (!_isCurrent(connectionGeneration)) {
      return const AndroidConnectionOutcome();
    }

    final rawYaml = subscriptionService.rawYaml;
    if (rawYaml == null || rawYaml.isEmpty) {
      return const AndroidConnectionOutcome(message: '请先添加并刷新订阅');
    }
    final subscriptionRevision = subscriptionService.revision;
    final preferredSettings = settingsService.settings;

    String? preparedConfigPath;
    String? runtimePortNotice;
    try {
      var started = false;
      for (var attempt = 0; attempt < 2; attempt++) {
        final settings = await clashService.prepareForStart(preferredSettings);
        if (!_isCurrent(connectionGeneration)) {
          return const AndroidConnectionOutcome();
        }
        if (!_isSubscriptionCurrent(subscriptionRevision)) {
          return const AndroidConnectionOutcome(message: '订阅已更新，请重新连接');
        }
        runtimePortNotice = clashService.lastRuntimePortAdjustmentMessage;

        final config = await clashService.generateClashConfigAsync(
          rawYaml,
          settings,
          preferredNodeName: nodeName,
        );
        if (!_isCurrent(connectionGeneration)) {
          return const AndroidConnectionOutcome();
        }
        if (!_isSubscriptionCurrent(subscriptionRevision)) {
          return const AndroidConnectionOutcome(message: '订阅已更新，请重新连接');
        }

        preparedConfigPath = await clashService.writeConfig(config);
        if (!_isCurrent(connectionGeneration)) {
          return const AndroidConnectionOutcome();
        }
        if (!_isSubscriptionCurrent(subscriptionRevision)) {
          return const AndroidConnectionOutcome(message: '订阅已更新，请重新连接');
        }

        started = await clashService.start(
          nodeName: nodeName,
          preparedConfigPath: preparedConfigPath,
        );
        if (!_isCurrent(connectionGeneration)) {
          return const AndroidConnectionOutcome();
        }
        final staleAfterStart =
            await _handleStaleSubscription(subscriptionRevision);
        if (staleAfterStart != null) {
          return AndroidConnectionOutcome(message: staleAfterStart);
        }
        if (started) break;

        final reason =
            clashService.lastStartError ?? androidUnknownCoreStartFailure;
        if (attempt == 0 &&
            RuntimePortConflictPolicy.isExplicitBindConflict(reason)) {
          // Native Android reports the bind failure before its worker has
          // finished releasing the bridge, VPN fd, and operation lease. Wait
          // for that cleanup barrier before regenerating ports; an immediate
          // retry would otherwise be rejected as CORE_BUSY.
          await clashService.stop();
          if (!_isCurrent(connectionGeneration)) {
            return const AndroidConnectionOutcome();
          }
          if (!_isSubscriptionCurrent(subscriptionRevision)) {
            return const AndroidConnectionOutcome(message: '订阅已更新，请重新连接');
          }
          await clashService.discardPreparedConfig(preparedConfigPath);
          preparedConfigPath = null;
          continue;
        }
        return AndroidConnectionOutcome(
          message: userFriendlyAndroidConnectionError(reason),
          preferredNodeSwitchSucceeded: false,
        );
      }
      if (!started) {
        return const AndroidConnectionOutcome(
          message: 'VPN 启动失败，请重试；若持续失败请打开诊断与运行日志',
          preferredNodeSwitchSucceeded: false,
        );
      }

      // 切换选中节点
      String? snapshotWarning;
      var preferredNodeSwitchSucceeded = true;
      String? runtimeNodeName;
      if (nodeName != null && nodeName.isNotEmpty) {
        final switchResult =
            await clashService.switchSelectedProxyForConnection(
          nodeName,
          connectionGeneration: connectionGeneration,
        );
        if (!_isCurrent(connectionGeneration)) {
          return const AndroidConnectionOutcome();
        }
        final staleAfterSwitch =
            await _handleStaleSubscription(subscriptionRevision);
        if (staleAfterSwitch != null) {
          return AndroidConnectionOutcome(message: staleAfterSwitch);
        }
        var preferredSwitchSucceeded =
            switchResult.liveSwitched && switchResult.intentCurrent;
        if (!preferredSwitchSucceeded) {
          runtimeNodeName = switchResult.runtimeNodeName;
          if (runtimeNodeName == null || runtimeNodeName.trim().isEmpty) {
            try {
              runtimeNodeName = await clashService.currentSelectedProxyName();
            } catch (_) {
              runtimeNodeName = null;
            }
          }
          if (!_isCurrent(connectionGeneration)) {
            return const AndroidConnectionOutcome();
          }
          if (!_isSubscriptionCurrent(subscriptionRevision)) {
            final staleAfterReadback =
                await _handleStaleSubscription(subscriptionRevision);
            return AndroidConnectionOutcome(message: staleAfterReadback);
          }
          preferredSwitchSucceeded =
              switchResult.intentCurrent && runtimeNodeName == nodeName;
          if (!preferredSwitchSucceeded) {
            preferredNodeSwitchSucceeded = false;
            snapshotWarning = '未能切换节点，当前连接仍保留';
          } else if (!switchResult.snapshotPersisted) {
            snapshotWarning = 'VPN 已连接，但快速启动节点信息保存失败';
          }
        } else if (!switchResult.snapshotPersisted) {
          snapshotWarning = 'VPN 已连接，但快速启动节点信息保存失败';
        }
        if (preferredSwitchSucceeded) {
          runtimeNodeName = switchResult.runtimeNodeName ?? nodeName;
        }
      }

      // Native startup has established the local VPN, protect monitor and API.
      // External reachability is advisory and updates connectivityWarning later.
      clashService.scheduleUserConnectivityObservation();
      return AndroidConnectionOutcome(
        message: snapshotWarning ?? runtimePortNotice,
        preferredNodeSwitchSucceeded: preferredNodeSwitchSucceeded,
        runtimeNodeName: runtimeNodeName,
      );
    } finally {
      if (preparedConfigPath != null) {
        await clashService.discardPreparedConfig(preparedConfigPath);
      }
    }
  }

  bool _isCurrent(int generation) => clashService.isConnectionIntentCurrent(
        generation,
        connected: true,
      );

  bool _isSubscriptionCurrent(int revision) =>
      subscriptionService.revision == revision;

  Future<String?> _handleStaleSubscription(int revision) async {
    if (_isSubscriptionCurrent(revision)) return null;
    if (clashService.isRunning) {
      try {
        await clashService.stop();
      } catch (_) {
        return '订阅已更新，但旧连接断开失败，请手动断开后重试';
      }
    }
    return '订阅已更新，请重新连接';
  }
}
