import '../services/clash_service.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';

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
  /// 返回 null 表示完全成功；返回非 null 可能是启动错误，也可能是
  /// 核心已运行后的连通性提示。调用方应以 [clashService.isRunning]
  /// 判断连接状态，以返回文本作为用户提示。
  Future<String?> connect(
    String? nodeName, {
    required int connectionGeneration,
  }) async {
    final rawYaml = subscriptionService.rawYaml;
    if (rawYaml == null || rawYaml.isEmpty) {
      return '请先添加并刷新订阅';
    }

    final settings = settingsService.settings;
    clashService.updateSettings(settings);

    // 生成配置
    final config = clashService.generateClashConfig(
      rawYaml,
      settings,
      preferredNodeName: nodeName,
    );

    String? preparedConfigPath;
    try {
      // 写入配置
      preparedConfigPath = await clashService.writeConfig(config);
      if (!_isCurrent(connectionGeneration)) return null;

      // 启动核心
      final success = await clashService.start(
        nodeName: nodeName,
        preparedConfigPath: preparedConfigPath,
      );

      if (!_isCurrent(connectionGeneration)) {
        return null;
      }

      if (!success) {
        return '连接失败: ${clashService.lastStartError ?? "无法启动VPN核心"}';
      }

      // 切换选中节点
      String? snapshotWarning;
      if (nodeName != null && nodeName.isNotEmpty) {
        final switchResult =
            await clashService.switchSelectedProxyForConnection(
          nodeName,
          connectionGeneration: connectionGeneration,
        );
        if (!_isCurrent(connectionGeneration)) {
          return null;
        }
        if (!switchResult.liveSwitched) {
          return '连接失败: 无法切换到所选节点';
        }
        if (!switchResult.snapshotPersisted) {
          snapshotWarning = 'VPN 已连接，但快速启动节点信息保存失败';
        }
      }

      // 验证连通性
      final connectivityWarning = await clashService.verifyUserConnectivity(
        shouldContinue: () => _isCurrent(connectionGeneration),
      );
      return connectivityWarning ?? snapshotWarning; // null = 完全成功
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
}
