import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_screen.dart';
import 'screens/subscription_screen.dart';
import 'screens/unlock_test_screen.dart';
import 'services/clash_service.dart' as clash;
import 'services/settings_service.dart';
import 'services/subscription_service.dart';
import 'services/tray_manager.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_status.dart';
import 'startup/window_state_store.dart';
import 'theme/app_theme.dart';
import 'widgets/liquid_glass.dart';

class SSRVpnApp extends StatefulWidget {
  const SSRVpnApp({super.key, required this.startupFlags});

  final StartupFlags startupFlags;

  @override
  State<SSRVpnApp> createState() => _SSRVpnAppState();
}

class _SSRVpnAppState extends State<SSRVpnApp> with WindowListener {
  final TrayManager _trayManager = TrayManager();

  int _currentIndex = 0;
  bool _isQuitting = false;
  bool _windowListenerAttached = false;
  Timer? _windowStateSaveDebounce;

  SettingsService? _settingsService;
  clash.ClashService? _clashService;
  SubscriptionService? _subscriptionService;

  @override
  void initState() {
    super.initState();
    StartupStatus.instance.addListener(_handleStartupStatusChanged);
    _handleStartupStatusChanged();
  }

  @override
  void dispose() {
    StartupStatus.instance.removeListener(_handleStartupStatusChanged);
    _windowStateSaveDebounce?.cancel();
    if (_windowListenerAttached) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    _clashService?.removeStatusListener(_handleCoreStatusChanged);
    _clashService?.stop();
    _trayManager.destroy();
    super.dispose();
  }

  void _handleStartupStatusChanged() {
    final status = StartupStatus.instance;

    if (status.windowManagerReady && !_windowListenerAttached) {
      try {
        windowManager.addListener(this);
        _windowListenerAttached = true;
      } catch (error, stack) {
        StartupLogger.error('Failed to attach window listener', error, stack);
      }
    }

    final nextClashService = status.clashService;
    if (nextClashService != null &&
        !identical(_clashService, nextClashService)) {
      _clashService?.removeStatusListener(_handleCoreStatusChanged);
      _clashService = nextClashService;
      _clashService!.addStatusListener(_handleCoreStatusChanged);
      _configureTrayCallbacks();
    }

    _settingsService = status.settingsService;
    _subscriptionService = status.subscriptionService;

    if (mounted) setState(() {});
  }

  void _configureTrayCallbacks() {
    _trayManager.onShowApp = () async {
      try {
        await windowManager.show();
        await windowManager.restore();
        await windowManager.focus();
      } catch (error, stack) {
        StartupLogger.error('Show app from tray failed', error, stack);
      }
    };
    _trayManager.onHideApp = () async {
      try {
        await windowManager.hide();
      } catch (error, stack) {
        StartupLogger.error('Hide app from tray failed', error, stack);
      }
    };
    _trayManager.onQuit = _quitApp;
    _trayManager.onConnectToggle = _handleTrayConnectToggle;
    _trayManager.isConnected = () => _clashService?.isRunning ?? false;
    unawaited(_trayManager.refreshMenu());
  }

  Future<void> _handleTrayConnectToggle() async {
    final core = _clashService;
    final settings = _settingsService;
    if (core == null || settings == null) return;

    try {
      if (core.isRunning) {
        await core.stop();
        return;
      }

      if (core.isStartupDisabled) {
        StartupLogger.warning(core.startupDisabledReason ?? 'Core disabled');
        return;
      }

      final rawYaml = _subscriptionService?.rawYaml;
      if (rawYaml == null || rawYaml.trim().isEmpty) return;

      final preferredNodeName = _defaultNodeName();
      final runtimeSettings = await core.prepareForStart(settings.settings);
      final config = core.generateClashConfig(
        rawYaml,
        runtimeSettings,
        preferredNodeName: preferredNodeName,
      );
      await core.writeConfig(config);
      final started = await core.start();
      if (started && preferredNodeName != null) {
        final switched = await core.switchSelectedProxy(preferredNodeName);
        if (switched) {
          await settings.updateLastSelectedNodeName(preferredNodeName);
        }
      }
    } catch (error, stack) {
      StartupLogger.error('Tray connect toggle failed', error, stack);
    } finally {
      await _trayManager.refreshMenu();
    }
  }

  String? _defaultNodeName() {
    final nodes = _subscriptionService?.allNodes ?? const [];
    if (nodes.isEmpty) return null;
    final remembered = _settingsService?.settings.lastSelectedNodeName;
    if (remembered != null &&
        remembered.isNotEmpty &&
        nodes.any((node) => node.name == remembered)) {
      return remembered;
    }
    return nodes.first.name;
  }

  void _handleCoreStatusChanged() {
    unawaited(_trayManager.refreshMenu());
  }

  Future<void> _quitApp() async {
    if (_isQuitting) return;
    _isQuitting = true;
    await _settingsService?.flush();
    await _clashService?.stop();
    await _trayManager.destroy();
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (error, stack) {
      StartupLogger.error('Window destroy failed', error, stack);
    }
  }

  @override
  void onWindowMinimize() async {
    final minimizeToTray = _settingsService?.settings.minimizeToTray ?? true;
    if (minimizeToTray && _trayManager.isReady) {
      try {
        await windowManager.hide();
      } catch (error, stack) {
        StartupLogger.error('Window hide on minimize failed', error, stack);
      }
    }
  }

  @override
  void onWindowClose() async {
    if (_isQuitting) return;
    final minimizeToTray = _settingsService?.settings.minimizeToTray ?? true;
    if (minimizeToTray && _trayManager.isReady) {
      try {
        await windowManager.hide();
      } catch (error, stack) {
        StartupLogger.error('Window hide on close failed', error, stack);
      }
      return;
    }
    await _quitApp();
  }

  @override
  void onWindowFocus() {
    if (mounted) setState(() {});
  }

  @override
  void onWindowResize() {
    _scheduleWindowStateSave();
  }

  @override
  void onWindowMove() {
    _scheduleWindowStateSave();
  }

  @override
  void onWindowResized() {
    _scheduleWindowStateSave();
  }

  @override
  void onWindowMoved() {
    _scheduleWindowStateSave();
  }

  void _scheduleWindowStateSave() {
    if (!StartupStatus.instance.windowManagerReady) return;
    _windowStateSaveDebounce?.cancel();
    _windowStateSaveDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_saveWindowState());
    });
  }

  Future<void> _saveWindowState() async {
    try {
      final bounds = await windowManager.getBounds();
      await WindowStateStore.save(bounds);
    } catch (error, stack) {
      StartupLogger.error('Saving window state failed', error, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = StartupStatus.instance;
    if (!status.servicesReady) {
      return _buildStartupShell(status);
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: _settingsService!),
        Provider<clash.ClashService>.value(value: _clashService!),
        ChangeNotifierProvider<SubscriptionService>.value(
          value: _subscriptionService!,
        ),
      ],
      child: Consumer<SettingsService>(
        builder: (context, settingsService, _) {
          final isDark = settingsService.settings.darkMode;
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'SSRVPN',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
            home: _MainShell(
              isDark: isDark,
              startupFlags: widget.startupFlags,
              failures: StartupStatus.instance.failures,
              currentIndex: _currentIndex,
              onIndexChanged: (index) => setState(() => _currentIndex = index),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStartupShell(StartupStatus status) {
    final failures = status.failures;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        backgroundColor: const Color(0xFF050508),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'SSRVPN',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    status.currentStep == null
                        ? '正在准备主窗口...'
                        : '正在执行 ${status.currentStep}...',
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  if (failures.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _StartupProblemPanel(failures: failures),
                  ],
                  const SizedBox(height: 14),
                  SelectableText(
                    '启动日志: ${StartupLogger.logPath}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


}

const _shellNavItems = [
  NavItem(
    icon: Icons.home_outlined,
    activeIcon: Icons.home_rounded,
    label: '首页',
  ),
  NavItem(
    icon: Icons.rss_feed_outlined,
    activeIcon: Icons.rss_feed_rounded,
    label: '订阅',
  ),
  NavItem(
    icon: Icons.fact_check_outlined,
    activeIcon: Icons.fact_check_rounded,
    label: '解锁',
  ),
];

class _MainShell extends StatelessWidget {
  const _MainShell({
    required this.isDark,
    required this.startupFlags,
    required this.failures,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool isDark;
  final StartupFlags startupFlags;
  final List<StartupFailure> failures;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: LiquidGlassBackdrop(
          child: Column(
            children: [
              if (startupFlags.safeMode)
                const _StartupBanner(
                  icon: Icons.health_and_safety_outlined,
                  color: AppTheme.warning,
                  title: '安全模式已启用',
                  message: '托盘、旧窗口位置和 Mihomo 自动初始化已跳过。',
                ),
              if (failures.isNotEmpty)
                _StartupBanner(
                  icon: Icons.error_outline,
                  color: AppTheme.error,
                  title: '部分启动步骤失败',
                  message: failures
                      .map((failure) => '${failure.step}: ${failure.message}')
                      .join('\n'),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth >= 900) {
                      return _DesktopShell(
                        isDark: isDark,
                        currentIndex: currentIndex,
                        onIndexChanged: onIndexChanged,
                      );
                    }

                    return _CompactShell(
                      currentIndex: currentIndex,
                      onIndexChanged: onIndexChanged,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.isDark,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool isDark;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            _GlassSideRail(
              isDark: isDark,
              currentIndex: currentIndex,
              onIndexChanged: onIndexChanged,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: LiquidGlassContainer(
                blur: 34,
                opacity: isDark ? 0.045 : 0.58,
                borderRadius: const BorderRadius.all(Radius.circular(30)),
                padding: EdgeInsets.zero,
                borderOpacity: isDark ? 0.16 : 0.74,
                shadowOpacity: isDark ? 0.44 : 0.12,
                child: _PageStack(currentIndex: currentIndex),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _PageStack(currentIndex: currentIndex)),
        LiquidGlassNavBar(
          currentIndex: currentIndex,
          items: _shellNavItems,
          onTap: onIndexChanged,
        ),
      ],
    );
  }
}

class _PageStack extends StatelessWidget {
  const _PageStack({required this.currentIndex});

  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: currentIndex,
      children: const [
        HomeScreen(),
        SubscriptionScreen(),
        UnlockTestScreen(),
      ],
    );
  }
}

class _GlassSideRail extends StatelessWidget {
  const _GlassSideRail({
    required this.isDark,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool isDark;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return LiquidGlassContainer(
      width: 220,
      blur: 38,
      opacity: isDark ? 0.055 : 0.62,
      borderRadius: const BorderRadius.all(Radius.circular(30)),
      padding: const EdgeInsets.all(16),
      borderOpacity: isDark ? 0.18 : 0.74,
      shadowOpacity: isDark ? 0.46 : 0.1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.primary, AppTheme.accentColor],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.28),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SSRVPN',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Liquid Glass',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          for (var index = 0; index < _shellNavItems.length; index++)
            _ShellRailItem(
              item: _shellNavItems[index],
              selected: currentIndex == index,
              onTap: () => onIndexChanged(index),
            ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.045)
                  : Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.8),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.memory_rounded, color: subColor, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'By—两颗西柚',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShellRailItem extends StatefulWidget {
  const _ShellRailItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ShellRailItem> createState() => _ShellRailItemState();
}

class _ShellRailItemState extends State<_ShellRailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = widget.selected || _hovered;
    final color = widget.selected
        ? AppTheme.primary
        : isDark
            ? AppTheme.textSecondary
            : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedSlide(
            offset: _hovered ? const Offset(0.018, 0) : Offset.zero,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.primary.withValues(
                        alpha: widget.selected
                            ? (isDark ? 0.16 : 0.1)
                            : (isDark ? 0.08 : 0.06),
                      )
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active
                      ? AppTheme.primary.withValues(
                          alpha: widget.selected ? 0.36 : 0.22,
                        )
                      : Colors.transparent,
                ),
                boxShadow: [
                  if (_hovered)
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.18),
                      blurRadius: 18,
                      spreadRadius: -12,
                      offset: const Offset(0, 8),
                    ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                      widget.selected
                          ? widget.item.activeIcon
                          : widget.item.icon,
                      color: _hovered && !widget.selected
                          ? AppTheme.primary
                          : color,
                      size: 21),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _hovered && !widget.selected
                            ? AppTheme.primary
                            : color,
                        fontSize: 14,
                        fontWeight:
                            widget.selected ? FontWeight.w800 : FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: widget.selected ? 1 : (_hovered ? 0.55 : 0),
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: AppTheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupProblemPanel extends StatelessWidget {
  const _StartupProblemPanel({required this.failures});

  final List<StartupFailure> failures;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 18 / 255),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.error.withValues(alpha: 50 / 255),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '启动过程中发现问题，但应用仍会继续尝试打开。',
            style: TextStyle(
              color: AppTheme.error,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final failure in failures.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${failure.step}: ${failure.message}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StartupBanner extends StatelessWidget {
  const _StartupBanner({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: (isDark ? 20 : 14) / 255),
          border: Border(
            bottom: BorderSide(color: color.withValues(alpha: 55 / 255)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
