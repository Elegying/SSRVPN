// ignore_for_file: unnecessary_library_name

library desktop_app;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/controllers/home_node_controller.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show
        AppConstants,
        AppErrorCode,
        AppFailure,
        DesktopConnectionCoordinator,
        DesktopConnectionFailure,
        SsrvpnAppBackdrop,
        SsrvpnBottomNavigation,
        desktopSubscriptionChangedMessage;
import 'package:ssrvpn_shared/widgets/crash_report_prompt.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_screen.dart';
import 'screens/subscription_screen.dart';
import 'services/app_shutdown.dart';
import 'services/clash_service.dart' as clash;
import 'services/settings_service.dart';
import 'services/subscription_service.dart';
import 'services/tray_manager.dart';
import 'services/windows_dpapi_secret_store.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_orchestrator.dart';
import 'startup/startup_status.dart';
import 'startup/window_state_store.dart';
import 'theme/app_theme.dart';
import 'widgets/windows_desktop_frame.dart';

part 'package:ssrvpn_shared/desktop_ui/desktop_app_shell_part.dart';
part 'app_runtime_actions_part.dart';
part 'app_startup_shell_part.dart';

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
  String? _runtimeNotice;
  Timer? _runtimeNoticeAutoClearTimer;
  bool _windowListenerAttached = false;
  Timer? _windowStateSaveDebounce;
  bool _secretRecoveryInProgress = false;
  String? _secretRecoveryError;

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
    _runtimeNoticeAutoClearTimer?.cancel();
    _windowStateSaveDebounce?.cancel();
    if (_windowListenerAttached) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    _clashService?.removeStatusListener(_handleCoreStatusChanged);
    _clashService?.onRuntimeNotice = null;
    final core = _clashService;
    if (core != null) {
      core.requestConnectionIntent(false);
      core.interruptPendingStart();
      unawaited(
        core
            .runConnectionTransition(core.stop)
            .catchError((Object error, StackTrace stack) {
          StartupLogger.error('Dispose core cleanup failed', error, stack);
        }),
      );
    }
    _trayManager.destroy();
    super.dispose();
  }

  void _handleStartupStatusChanged() {
    final status = StartupStatus.instance;
    final nextSubscriptionService = status.subscriptionService;
    if (_subscriptionService != null &&
        !identical(_subscriptionService, nextSubscriptionService)) {
      _clashService?.clearDesktopConnectionRecoveryPlan();
    }

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
      _clashService?.onRuntimeNotice = null;
      _clashService = nextClashService;
      _clashService!.addStatusListener(_handleCoreStatusChanged);
      _clashService!.onRuntimeNotice = (message) {
        unawaited(_presentRuntimeNotice(message));
      };
      _configureTrayCallbacks();
    }

    _settingsService = status.settingsService;
    _subscriptionService = nextSubscriptionService;

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
    _trayManager.onQuit = () async {
      await _quitApp();
    };
    _trayManager.onConnectToggle = _handleTrayConnectToggle;
    _trayManager.isConnected = () => _clashService?.isRunning ?? false;
    _trayManager.runtimeProxyPort = () =>
        _clashService?.runtimeProxyPort ??
        _settingsService?.settings.proxyPort ??
        7890;
    _refreshTrayStatus();
  }

  String? _defaultNodeName() {
    final nodes = _subscriptionService?.allNodes ?? const [];
    final remembered = _settingsService?.settings.lastSelectedNodeName;
    return HomeNodeController.resolveDefaultNodeFrom(nodes, remembered)?.name;
  }

  Future<void> _presentTrayFailure(String reason) =>
      _presentRuntimeNotice('连接失败：$reason');

  Future<void> _presentRuntimeNotice(String message) async {
    _runtimeNoticeAutoClearTimer?.cancel();
    _runtimeNoticeAutoClearTimer = null;
    if (mounted) {
      setState(() {
        _runtimeNotice = message;
        _currentIndex = 0;
      });
      _runtimeNoticeAutoClearTimer = scheduleSuccessfulRuntimeNoticeClear(
        message: message,
        currentMessage: () => _runtimeNotice,
        clear: _clearRuntimeNotice,
      );
    }
    try {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (error, stack) {
      StartupLogger.error('Present tray failure failed', error, stack);
    }
  }

  void _clearRuntimeNotice() {
    _runtimeNoticeAutoClearTimer?.cancel();
    _runtimeNoticeAutoClearTimer = null;
    if (mounted && _runtimeNotice != null) {
      setState(() => _runtimeNotice = null);
    }
  }

  void _handleCoreStatusChanged() {
    if (mounted &&
        (_clashService?.isRunning ?? false) &&
        _runtimeNotice != null &&
        !isSuccessfulRuntimeNotice(_runtimeNotice)) {
      _clearRuntimeNotice();
    }
    _refreshTrayStatus();
  }

  void _refreshTrayStatus() {
    final core = _clashService;
    final connected = core?.isRunning ?? false;
    final port =
        core?.runtimeProxyPort ?? _settingsService?.settings.proxyPort ?? 7890;
    unawaited(_trayManager.refreshMenu());
    unawaited(
      _trayManager.setToolTip(
        connected ? 'SSRVPN · 已连接 · HTTP 127.0.0.1:$port' : 'SSRVPN · 未连接',
      ),
    );
  }

  Future<bool> _quitApp() async {
    if (_isQuitting) return false;
    _isQuitting = true;
    final failures = await runWindowsAppShutdown(
      hideWindow: windowManager.hide,
      flushSettings: () async => _settingsService?.flush(),
      stopCore: () async {
        final core = _clashService;
        if (core == null) return;
        core.requestConnectionIntent(false);
        core.interruptPendingStart();
        await core.runConnectionTransition(core.stop);
      },
      destroyTray: _trayManager.destroy,
      allowWindowClose: () => windowManager.setPreventClose(false),
      destroyWindow: windowManager.destroy,
    );
    for (final failure in failures) {
      StartupLogger.error(
        'Quit cleanup step ${failure.step} failed',
        failure.error,
        failure.stackTrace,
      );
      StartupLogger.writeDesktopFailureReportSync(
        'Quit cleanup failed',
        error: failure.error,
        stack: failure.stackTrace,
      );
    }
    if (!isWindowsAppShutdownSafeToExit(failures)) {
      _isQuitting = false;
      final blockingFailure = failures.firstWhere(
        (failure) => failure.step == 2 || failure.step == 5,
      );
      final reason = blockingFailure.error
          .toString()
          .replaceFirst('Bad state: ', '')
          .replaceFirst('StateError: ', '');
      await _presentRuntimeNotice('退出未完成：$reason。请稍后再次退出');
      return false;
    }
    return true;
  }

  @override
  void onWindowMinimize() async {
    if (_trayManager.isReady) {
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
    if (_trayManager.isReady) {
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

  Future<void> _confirmWindowsSecretRecovery(
    BuildContext context,
    String secretPath,
  ) async {
    if (_secretRecoveryInProgress) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: buildWindowsApiSecretRecoveryDialog,
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _secretRecoveryInProgress = true;
      _secretRecoveryError = null;
    });
    try {
      final store = WindowsDpapiSecretStore(File(secretPath).parent.path);
      await store.isolateUnreadableEnvelope();
      SettingsService.resetInstanceForRecovery();
      await StartupOrchestrator(widget.startupFlags).retryCoreInitialization();
      if (mounted) {
        setState(() => _secretRecoveryInProgress = false);
      }
    } catch (error, stack) {
      StartupLogger.error('Windows API secret recovery failed', error, stack);
      if (!mounted) return;
      setState(() {
        _secretRecoveryInProgress = false;
        _secretRecoveryError = '恢复失败：$error。旧密文和用户数据仍已保留，请重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = StartupStatus.instance;
    if (!status.servicesReady) {
      return _buildStartupShell(status);
    }

    final desktopShell = CrashReportPrompt(
      child: _DesktopAppShell(
        safeMode: widget.startupFlags.safeMode,
        startupFailureMessages: StartupStatus.instance.failures
            .map((failure) => failure.userSummary)
            .toList(growable: false),
        runtimeNotice: _runtimeNotice,
        currentIndex: _currentIndex,
        onIndexChanged: (index) => setState(() => _currentIndex = index),
      ),
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: _settingsService!),
        Provider<clash.ClashService>.value(value: _clashService!),
        ChangeNotifierProvider<SubscriptionService>.value(
          value: _subscriptionService!,
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SSRVPN',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: _withWindowsFrame(status, desktopShell),
      ),
    );
  }

  Widget _withWindowsFrame(StartupStatus status, Widget child) {
    if (!status.windowManagerReady) return child;
    return WindowsDesktopFrame(child: child);
  }

  Widget _buildStartupShell(StartupStatus status) {
    final failures = status.failures;
    final startupFailed = status.completed && !status.servicesReady;
    final startupShell = buildWindowsStartupScaffold(
      startupFailed: startupFailed,
      startupProgress: _startupProgress(status),
      failures: failures,
      secretRecoveryError: _secretRecoveryError,
      secretRecoveryInProgress: _secretRecoveryInProgress,
      onSecretRecovery: (buttonContext, secretPath) =>
          _confirmWindowsSecretRecovery(
        buttonContext,
        secretPath,
      ),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: _withWindowsFrame(status, startupShell),
    );
  }
}
