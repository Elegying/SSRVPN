import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:system_tray/system_tray.dart';

typedef VoidCallback = void Function();

/// Windows 系统托盘管理器
class TrayManager {
  static final TrayManager _instance = TrayManager._();
  factory TrayManager() => _instance;
  TrayManager._();

  final SystemTray _systemTray = SystemTray();
  bool _initialized = false;

  /// 托盘是否已成功初始化
  bool get isReady => _initialized;

  // 回调
  void Function()? onShowApp;
  void Function()? onHideApp;
  Future<void> Function()? onQuit;
  void Function()? onConnectToggle;
  bool Function()? isConnected;
  int Function()? runtimeProxyPort;

  Future<void> requestQuit() async {
    await onQuit?.call();
  }

  /// 初始化系统托盘，返回是否成功
  Future<bool> init() async {
    if (!Platform.isWindows) return false;
    if (_initialized) return true;

    try {
      // 解析图标路径
      final iconAssetPath = _resolveIconAssetPath();
      if (iconAssetPath == null) {
        AppLogger.warning('Tray', '找不到任何可用的托盘图标文件');
        return false;
      }

      AppLogger.info('Tray', '使用图标资源: $iconAssetPath');

      // 初始化系统托盘
      final initialized = await _systemTray.initSystemTray(
        title: 'SSRVPN',
        iconPath: iconAssetPath,
        toolTip: 'SSRVPN',
      );
      if (!initialized) {
        AppLogger.warning('Tray', '原生插件未能创建系统托盘图标');
        return false;
      }

      // 构建右键菜单
      await _buildMenu();

      // 注册事件处理
      _systemTray.registerSystemTrayEventHandler((String eventType) {
        if (eventType == kSystemTrayEventClick) {
          onShowApp?.call();
        } else if (eventType == kSystemTrayEventRightClick) {
          _systemTray.popUpContextMenu();
        }
      });

      _initialized = true;
      AppLogger.info('Tray', '系统托盘初始化成功');
      return true;
    } catch (e, stack) {
      AppLogger.error('Tray', '初始化异常', error: e, stack: stack);
      _initialized = false;
      return false;
    }
  }

  /// system_tray 会自行将资源路径拼接到 data/flutter_assets 下，
  /// 因此这里必须返回 Flutter 资源相对路径，不能返回绝对路径。
  String? _resolveIconAssetPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final flutterAssetsDir = p.join(exeDir, 'data', 'flutter_assets');

    final candidates = [p.join('assets', 'icon.ico')];

    for (final assetPath in candidates) {
      final filePath = p.join(flutterAssetsDir, assetPath);
      if (File(filePath).existsSync()) {
        return assetPath;
      }
    }
    return null;
  }

  /// 构建右键菜单
  Future<void> _buildMenu() async {
    final connected = isConnected?.call() ?? false;
    final port = connected ? runtimeProxyPort?.call() : null;

    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: '显示主窗口', onClicked: (_) => onShowApp?.call()),
      MenuSeparator(),
      if (port != null) ...[
        MenuItemLabel(label: 'HTTP 代理：127.0.0.1:$port', enabled: false),
        MenuSeparator(),
      ],
      MenuItemLabel(
        label: connected ? '断开连接' : '连接',
        onClicked: (_) => onConnectToggle?.call(),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '退出 SSRVPN',
        onClicked: (_) => unawaited(requestQuit()),
      ),
    ]);

    await _systemTray.setContextMenu(menu);
  }

  /// 刷新菜单状态
  Future<void> refreshMenu() async {
    if (!_initialized) return;
    try {
      await _buildMenu();
    } catch (e, stack) {
      AppLogger.error('Tray', 'refreshMenu failed', error: e, stack: stack);
    }
  }

  /// 更新工具提示
  Future<void> setToolTip(String text) async {
    if (!_initialized) return;
    try {
      await _systemTray.setToolTip(text);
    } catch (_) {}
  }

  /// 销毁托盘图标
  Future<void> destroy() async {
    if (!_initialized) return;
    try {
      await _systemTray.destroy();
    } catch (_) {}
    _initialized = false;
  }
}
