import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 通知栏常驻服务
///
/// 替代 macOS/Windows 的托盘图标功能：
/// - 前台通知显示连接状态
/// - 通知栏快捷操作（连接/断开/切换节点）
/// - 通知通道管理
class NotificationService {
  static NotificationService? _instance;
  static const _channel = MethodChannel('com.ssrvpn/notification');

  bool _initialized = false;
  bool _nativeNotificationsAvailable = true;

  NotificationService._();

  static NotificationService get instance {
    _instance ??= NotificationService._();
    return _instance!;
  }

  /// 初始化通知通道
  Future<void> initialize() async {
    if (_initialized) return;
    await _invokeNative('initialize', label: '初始化');
    _initialized = true;
  }

  /// 显示连接状态通知（前台 service 常驻）
  Future<void> showConnectedNotification({
    required String nodeName,
    required String proxyMode,
    int? txBytes,
    int? rxBytes,
  }) async {
    await _invokeNative(
      'showConnected',
      label: '显示连接通知',
      arguments: {
        'nodeName': nodeName,
        'proxyMode': proxyMode,
        'txBytes': txBytes ?? 0,
        'rxBytes': rxBytes ?? 0,
      },
    );
  }

  /// 更新流量信息
  Future<void> updateTraffic(int txBytes, int rxBytes) async {
    await _invokeNative(
      'updateTraffic',
      label: '更新流量',
      arguments: {
        'txBytes': txBytes,
        'rxBytes': rxBytes,
      },
    );
  }

  /// 显示断开状态通知
  Future<void> showDisconnectedNotification() async {
    await _invokeNative('showDisconnected', label: '显示断开通知');
  }

  /// 隐藏所有通知
  Future<void> dismissAll() async {
    await _invokeNative('dismissAll', label: '关闭通知');
  }

  Future<void> _invokeNative(
    String method, {
    required String label,
    Object? arguments,
  }) async {
    if (!_nativeNotificationsAvailable) return;
    try {
      await _channel.invokeMethod(method, arguments);
    } on MissingPluginException {
      // Android 的常驻通知由 SsrvpnVpnService 前台服务负责；没有额外
      // MethodChannel 实现时静默降级，避免每次连接都打印误导性的错误。
      _nativeNotificationsAvailable = false;
    } catch (e) {
      debugPrint('[NotificationService] $label失败: $e');
    }
  }

  /// 设置通知快捷操作回调
  void onNotificationAction(Function(String action) callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAction') {
        callback(call.arguments as String);
      }
    });
  }
}
