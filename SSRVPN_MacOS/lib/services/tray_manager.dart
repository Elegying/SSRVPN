import 'dart:io';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:tray_manager/tray_manager.dart' as tm;

typedef VoidCallback = void Function();

/// macOS menu bar tray manager with the same surface as the Windows client.
class TrayManager with tm.TrayListener {
  static final TrayManager _instance = TrayManager._();
  factory TrayManager() => _instance;
  TrayManager._();

  bool _initialized = false;

  bool get isReady => _initialized;

  void Function()? onShowApp;
  void Function()? onHideApp;
  void Function()? onQuit;
  void Function()? onConnectToggle;
  bool Function()? isConnected;

  Future<bool> init() async {
    if (!Platform.isMacOS) return false;
    if (_initialized) return true;

    try {
      tm.trayManager.addListener(this);
      await tm.trayManager.setIcon('assets/tray_icon.png', isTemplate: false);
      await tm.trayManager.setToolTip('SSRVPN');
      await _buildMenu();
      _initialized = true;
      return true;
    } catch (e, stack) {
      AppLogger.error('Tray', 'init failed', error: e, stack: stack);
      _initialized = false;
      return false;
    }
  }

  Future<void> _buildMenu() async {
    final connected = isConnected?.call() ?? false;
    final menu = tm.Menu(
      items: [
        tm.MenuItem(key: 'show', label: '显示主窗口'),
        tm.MenuItem.separator(),
        tm.MenuItem(key: 'toggle', label: connected ? '断开连接' : '连接'),
        tm.MenuItem.separator(),
        tm.MenuItem(key: 'quit', label: '退出 SSRVPN'),
      ],
    );
    await tm.trayManager.setContextMenu(menu);
  }

  Future<void> refreshMenu() async {
    if (!_initialized) return;
    try {
      await _buildMenu();
    } catch (e, stack) {
      AppLogger.error('Tray', 'refreshMenu failed', error: e, stack: stack);
    }
  }

  Future<void> setToolTip(String text) async {
    if (!_initialized) return;
    try {
      await tm.trayManager.setToolTip(text);
    } catch (_) {}
  }

  Future<void> destroy() async {
    if (!_initialized) return;
    try {
      tm.trayManager.removeListener(this);
      await tm.trayManager.destroy();
    } catch (_) {}
    _initialized = false;
  }

  @override
  void onTrayIconMouseDown() {
    onShowApp?.call();
  }

  @override
  void onTrayIconRightMouseDown() {
    tm.trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(tm.MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        onShowApp?.call();
        break;
      case 'toggle':
        onConnectToggle?.call();
        break;
      case 'quit':
        onQuit?.call();
        break;
    }
  }
}
