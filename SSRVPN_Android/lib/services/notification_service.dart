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

  NotificationService._();

  static NotificationService get instance {
    _instance ??= NotificationService._();
    return _instance!;
  }

  /// 初始化通知通道
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await _channel.invokeMethod('initialize');
      _initialized = true;
    } catch (e) {
      debugPrint('[NotificationService] 初始化失败: $e');
    }
  }

  /// 显示连接状态通知（前台 service 常驻）
  Future<void> showConnectedNotification({
    required String nodeName,
    required String proxyMode,
    int? txBytes,
    int? rxBytes,
  }) async {
    try {
      await _channel.invokeMethod('showConnected', {
        'nodeName': nodeName,
        'proxyMode': proxyMode,
        'txBytes': txBytes ?? 0,
        'rxBytes': rxBytes ?? 0,
      });
    } catch (e) {
      debugPrint('[NotificationService] 显示连接通知失败: $e');
    }
  }

  /// 更新流量信息
  Future<void> updateTraffic(int txBytes, int rxBytes) async {
    try {
      await _channel.invokeMethod('updateTraffic', {
        'txBytes': txBytes,
        'rxBytes': rxBytes,
      });
    } catch (e) {
      debugPrint('[NotificationService] 更新流量失败: $e');
    }
  }

  /// 显示断开状态通知
  Future<void> showDisconnectedNotification() async {
    try {
      await _channel.invokeMethod('showDisconnected');
    } catch (e) {
      debugPrint('[NotificationService] 显示断开通知失败: $e');
    }
  }

  /// 隐藏所有通知
  Future<void> dismissAll() async {
    try {
      await _channel.invokeMethod('dismissAll');
    } catch (e) {
      debugPrint('[NotificationService] 关闭通知失败: $e');
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
