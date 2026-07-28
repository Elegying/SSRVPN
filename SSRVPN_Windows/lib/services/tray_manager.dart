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
  TrayManager._({
    bool? isWindowsOverride,
    String? Function()? iconAssetPathResolver,
    Future<bool> Function(String iconAssetPath)? nativeTrayInitializer,
    Future<bool> Function(String iconAssetPath)? nativeTrayVerifier,
    Future<void> Function()? initialMenuBuilder,
    void Function()? eventHandlerRegistrar,
  })  : _isWindowsOverride = isWindowsOverride,
        _iconAssetPathResolver = iconAssetPathResolver,
        _nativeTrayInitializer = nativeTrayInitializer,
        _nativeTrayVerifier = nativeTrayVerifier,
        _initialMenuBuilder = initialMenuBuilder,
        _eventHandlerRegistrar = eventHandlerRegistrar;

  /// Creates an isolated manager for deterministic native-boundary tests.
  factory TrayManager.forTesting({
    required Future<bool> Function(String iconAssetPath) initializeNativeTray,
    required Future<bool> Function(String iconAssetPath) verifyNativeTray,
    Future<void> Function()? buildMenu,
    void Function()? registerEventHandler,
    String iconAssetPath = 'assets/icon.ico',
  }) =>
      TrayManager._(
        isWindowsOverride: true,
        iconAssetPathResolver: () => iconAssetPath,
        nativeTrayInitializer: initializeNativeTray,
        nativeTrayVerifier: verifyNativeTray,
        initialMenuBuilder: buildMenu ?? () async {},
        eventHandlerRegistrar: registerEventHandler ?? () {},
      );

  SystemTray? _systemTrayInstance;
  SystemTray get _systemTray => _systemTrayInstance ??= SystemTray();
  final bool? _isWindowsOverride;
  final String? Function()? _iconAssetPathResolver;
  final Future<bool> Function(String iconAssetPath)? _nativeTrayInitializer;
  final Future<bool> Function(String iconAssetPath)? _nativeTrayVerifier;
  final Future<void> Function()? _initialMenuBuilder;
  final void Function()? _eventHandlerRegistrar;
  bool _initialized = false;
  Future<bool>? _initializationOperation;
  String? _lastError;

  /// 托盘是否已成功初始化
  bool get isReady => _initialized;

  /// 最近一次托盘初始化失败原因。
  String? get lastError => _lastError;

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
  Future<bool> init() {
    if (!(_isWindowsOverride ?? Platform.isWindows)) {
      _lastError = '当前平台不支持 Windows 系统托盘';
      return Future<bool>.value(false);
    }
    if (_initialized) return Future<bool>.value(true);
    final current = _initializationOperation;
    if (current != null) return current;

    final operation = _initialize();
    _initializationOperation = operation;
    operation.then<void>(
      (_) => _clearInitializationOperation(operation),
      onError: (_, __) => _clearInitializationOperation(operation),
    );
    return operation;
  }

  Future<bool> _initialize() async {
    _lastError = null;
    try {
      // 解析图标路径
      final iconAssetPath =
          _iconAssetPathResolver?.call() ?? _resolveIconAssetPath();
      if (iconAssetPath == null) {
        return _failInitialization('找不到任何可用的托盘图标文件');
      }

      AppLogger.info('Tray', '使用图标资源: $iconAssetPath');

      // 初始化系统托盘
      final initializeNativeTray = _nativeTrayInitializer;
      final initialized = initializeNativeTray != null
          ? await initializeNativeTray(iconAssetPath)
          : await _systemTray.initSystemTray(
              title: 'SSRVPN',
              iconPath: iconAssetPath,
              toolTip: 'SSRVPN',
            );
      if (!initialized) {
        return _failInitialization('原生插件未能创建系统托盘图标');
      }

      // system_tray 在 Windows 上可能把失败的 NIM_DELETE 报告为成功，
      // 同时保留 installed 标记并销毁旧 HICON。显式重设图标和提示可验证
      // 托盘仍能被 Shell 修改，避免把部分销毁状态误报为 ready。
      final verifyNativeTray = _nativeTrayVerifier;
      final verified = verifyNativeTray != null
          ? await verifyNativeTray(iconAssetPath)
          : await _systemTray.setSystemTrayInfo(
              iconPath: iconAssetPath,
              toolTip: 'SSRVPN',
            );
      if (!verified) {
        return _failInitialization('原生系统托盘状态复核失败');
      }

      // 构建右键菜单
      final buildInitialMenu = _initialMenuBuilder;
      if (buildInitialMenu != null) {
        await buildInitialMenu();
      } else {
        await _buildMenu();
      }

      // 注册事件处理
      final registerEventHandler = _eventHandlerRegistrar;
      if (registerEventHandler != null) {
        registerEventHandler();
      } else {
        _systemTray.registerSystemTrayEventHandler((String eventType) {
          if (eventType == kSystemTrayEventClick) {
            onShowApp?.call();
          } else if (eventType == kSystemTrayEventRightClick) {
            _systemTray.popUpContextMenu();
          }
        });
      }

      _initialized = true;
      AppLogger.info('Tray', '系统托盘初始化成功');
      return true;
    } catch (e, stack) {
      _lastError = '系统托盘初始化异常: $e';
      AppLogger.error('Tray', '初始化异常', error: e, stack: stack);
      _initialized = false;
      return false;
    }
  }

  bool _failInitialization(String error) {
    _lastError = error;
    _initialized = false;
    AppLogger.warning('Tray', error);
    return false;
  }

  void _clearInitializationOperation(Future<bool> operation) {
    if (identical(_initializationOperation, operation)) {
      _initializationOperation = null;
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
