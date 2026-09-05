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
  if (raw == '请先添加并刷新订阅') return raw;
  if (raw.startsWith('订阅已更新')) return '订阅已更新，请重新连接以使用最新配置';
  if (lower.contains('core_start_')) {
    return AppFailure.fromMessage(error).userMessage;
  }
  if (lower.contains('stop_incomplete') || raw.contains('正在释放系统资源')) {
    return 'VPN 正在释放系统资源，请等待几秒后重试';
  }
  if (lower.contains('stop_failed') || raw.contains('VPN 断开失败')) {
    return 'VPN 未能完成断开，请再次点击断开；仍失败请查看诊断中的核心状态';
  }
  if (raw.contains('无法保存连接恢复信息')) {
    return '无法保存连接恢复信息，本次连接已回滚。请检查设备可用空间后重试';
  }
  if (raw.contains('连接已取消')) return '连接已取消';
  if (raw.contains('连接已中断')) return '连接已中断，请重新连接';

  // Older native builds used localized text instead of stable stage codes.
  // Normalize those aliases once, then reuse the shared safe failure copy.
  const legacyStages = <String, String>{
    'missing required arguments': 'CORE_START_CONFIG',
    '连接参数不完整': 'CORE_START_CONFIG',
    'invalid_args': 'CORE_START_CONFIG',
    'vpn establish failed': 'CORE_START_TUN',
    '创建 vpn 接口': 'CORE_START_TUN',
    'vpn 网络保护服务': 'CORE_START_TUN',
    'vpn 凭据不可用': 'CORE_START_API_AUTH',
    'vpn 配置不可用': 'CORE_START_CONFIG',
    '用户拒绝了 vpn 权限': 'VPN_PERMISSION_DENIED',
    'permission_denied': 'VPN_PERMISSION_DENIED',
    'health check timeout': 'CORE_API_UNAVAILABLE',
    'local api': 'CORE_API_UNAVAILABLE',
    '本地控制服务': 'CORE_API_UNAVAILABLE',
    'bridge.start': 'CORE_START_TIMEOUT',
    'core start timeout': 'CORE_START_TIMEOUT',
    'core_timeout': 'CORE_START_TIMEOUT',
    'vpn 启动超时': 'CORE_START_TIMEOUT',
    'core_busy': 'CORE_START_BUSY',
    '核心正在启动': 'CORE_START_BUSY',
    '核心正在清理': 'CORE_START_BUSY',
    'mihomo 原生组件不可用': 'CORE_START_COMPONENT',
  };
  for (final entry in legacyStages.entries) {
    if (lower.contains(entry.key)) {
      return AppFailure.fromMessage(entry.value).userMessage;
    }
  }
  return AppFailure.fromMessage(error).userMessage;
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
          message: reason,
          preferredNodeSwitchSucceeded: false,
        );
      }
      if (!started) {
        return const AndroidConnectionOutcome(
          message: androidUnknownCoreStartFailure,
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
