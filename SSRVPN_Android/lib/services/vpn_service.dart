import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android VPN Service 生命周期管理
///
/// 封装与原生 VPN Service 的 MethodChannel 通信：
/// - 启动/停止 VPN
/// - 获取 VPN 状态
/// - 切换代理节点
/// - 流量统计
///
/// @Deprecated 预留 Android 原生 VPN Service 集成，当前由 ClashService tun2socks 接管
@Deprecated('预留 Android 原生 VPN Service 集成，当前由 ClashService tun2socks 接管')
class VpnService {
  static VpnService? _instance;
  static const _channel = MethodChannel('com.ssrvpn/vpn');

  final _statusController = StreamController<VpnStatus>.broadcast();
  VpnStatus _currentStatus = VpnStatus.disconnected;
  int _txBytes = 0;
  int _rxBytes = 0;
  Timer? _trafficTimer;

  VpnService._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static VpnService get instance {
    _instance ??= VpnService._();
    return _instance!;
  }

  /// VPN 状态流
  Stream<VpnStatus> get statusStream => _statusController.stream;

  /// 当前状态
  VpnStatus get currentStatus => _currentStatus;

  /// 发送字节数
  int get txBytes => _txBytes;

  /// 接收字节数
  int get rxBytes => _rxBytes;

  /// 是否已连接
  bool get isConnected => _currentStatus == VpnStatus.connected;

  /// 是否正在连接
  bool get isConnecting => _currentStatus == VpnStatus.connecting;

  /// 启动 VPN
  Future<bool> start({
    required String configPath,
    required String proxyHost,
    required int proxyPort,
    required int socksPort,
    required int apiPort,
  }) async {
    if (_currentStatus == VpnStatus.connected) return true;
    _updateStatus(VpnStatus.connecting);

    try {
      final result = await _channel.invokeMethod<bool>('start', {
        'configPath': configPath,
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'socksPort': socksPort,
        'apiPort': apiPort,
      });
      if (result == true) {
        _updateStatus(VpnStatus.connected);
        _startTrafficMonitor();
        return true;
      }
      _updateStatus(VpnStatus.disconnected);
      return false;
    } catch (e) {
      debugPrint('[VpnService] 启动失败: $e');
      _updateStatus(VpnStatus.disconnected);
      return false;
    }
  }

  /// 停止 VPN
  Future<void> stop() async {
    if (_currentStatus == VpnStatus.disconnected) return;
    _stopTrafficMonitor();
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[VpnService] 停止失败: $e');
    }
    _updateStatus(VpnStatus.disconnected);
  }

  /// 切换代理节点
  Future<void> switchProxy(String proxyName) async {
    try {
      await _channel.invokeMethod('switchProxy', {'name': proxyName});
    } catch (e) {
      debugPrint('[VpnService] 切换节点失败: $e');
    }
  }

  /// 获取流量统计
  Future<({int tx, int rx})> getTrafficStats() async {
    try {
      final result = await _channel.invokeMethod('getTrafficStats');
      if (result is Map) {
        _txBytes = result['tx'] as int? ?? 0;
        _rxBytes = result['rx'] as int? ?? 0;
      }
    } catch (e) {
      debugPrint('[VpnService] 获取流量统计失败: $e');
    }
    return (tx: _txBytes, rx: _rxBytes);
  }

  /// 是否支持 TUN 模式
  Future<bool> isTunSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isTunSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求 VPN 权限
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  void _startTrafficMonitor() {
    _trafficTimer?.cancel();
    _trafficTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      getTrafficStats();
    });
  }

  void _stopTrafficMonitor() {
    _trafficTimer?.cancel();
    _trafficTimer = null;
  }

  void _updateStatus(VpnStatus status) {
    if (_currentStatus == status) return;
    _currentStatus = status;
    _statusController.add(status);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onStatusChanged':
        final status = call.arguments as String?;
        if (status == 'connected') {
          _updateStatus(VpnStatus.connected);
          _startTrafficMonitor();
        } else if (status == 'disconnected') {
          _stopTrafficMonitor();
          _updateStatus(VpnStatus.disconnected);
        } else if (status == 'connecting') {
          _updateStatus(VpnStatus.connecting);
        }
        break;
      case 'onTrafficUpdate':
        final args = call.arguments as Map?;
        if (args != null) {
          _txBytes = args['tx'] as int? ?? _txBytes;
          _rxBytes = args['rx'] as int? ?? _rxBytes;
        }
        break;
    }
  }

  void dispose() {
    _stopTrafficMonitor();
    _statusController.close();
  }
}

enum VpnStatus {
  disconnected,
  connecting,
  connected,
}
