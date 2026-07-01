import 'dart:async';
import 'package:flutter/services.dart';
import '../services/clash_service.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';
import '../services/update_service.dart';
import 'startup_flags.dart';
import 'startup_logger.dart';
import 'startup_status.dart';

/// Android 启动流程编排器
class StartupOrchestrator {
  final StartupFlags flags;
  final StartupStatus status = StartupStatus();
  final SettingsService? _settings;
  final ClashService? _clash;
  final SubscriptionService? _subscription;

  StartupOrchestrator({
    required SettingsService? settings,
    required ClashService? clash,
    required SubscriptionService? subscription,
    required this.flags,
  })  : _settings = settings,
        _clash = clash,
        _subscription = subscription;

  Future<void> start() async {
    status.start();
    StartupLogger.info('启动流程开始');

    try {
      if (_clash == null || _subscription == null) {
        StartupLogger.error('startup', '核心服务未就绪');
        status.fail('核心服务未就绪');
        return;
      }

      status.recordStep('通知服务', '初始化通知通道');
      await _initNotifications();

      if (!flags.skipUpdateCheck &&
          (_settings?.settings.autoCheckUpdate ?? true)) {
        status.recordStep('更新检查', '检查新版本');
        await _checkForUpdate();
      }

      final autoConnect = flags.autoConnect ||
          (_settings?.settings.autoConnectOnStartup ?? false);
      if (autoConnect) {
        status.recordStep('自动连接', '尝试自动连接 VPN');
        await _autoConnect();
      }

      status.recordStep('原生同步', '同步设置到原生层');
      await _syncToNative();

      status.complete();
      StartupLogger.info('启动流程完成');
    } catch (e, stack) {
      status.fail(e.toString());
      StartupLogger.error('启动流程失败: $e', stack);
    }
  }

  Future<void> _initNotifications() async {
    try {
      final ns = NotificationService.instance;
      await ns.initialize();
      if (_settings?.settings.autoConnectOnStartup == true) {
        await ns.showConnectedNotification(
            nodeName: "SSRVPN", proxyMode: "rule");
      }
    } catch (e) {
      StartupLogger.warn('通知服务初始化失败: $e');
    }
  }

  Future<void> _checkForUpdate() async {
    try {
      await UpdateService.checkForUpdate("2.0.1");
    } catch (e) {
      StartupLogger.warn('更新检查失败: $e');
    }
  }

  Future<void> _autoConnect() async {
    try {
      if (_clash == null) return;
      final node = _settings?.settings.lastSelectedNodeName;
      if (node != null && node.isNotEmpty) {
        await _clash!.switchSelectedProxy(node);
      }
      await _clash!.start();
    } catch (e) {
      // 记录警告但不阻止启动流程
      // 节点列表可能为空或 switchSelectedProxy 因节点不存在而失败
      // 用户可在连接后通过 clash API 手动切换节点
      StartupLogger.warn('自动连接警告 (非致命): $e');
    }
  }

  Future<void> _syncToNative() async {
    try {
      const channel = MethodChannel('com.ssrvpn/native');
      final s = _settings?.settings;
      await channel.invokeMethod('syncSettings', {
        'proxyPort': s?.proxyPort ?? 7890,
        'autoConnect': s?.autoConnectOnStartup ?? false,
      });
    } catch (e) {
      StartupLogger.warn('原生同步失败: $e');
    }
  }
}
