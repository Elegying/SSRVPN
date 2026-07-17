// ignore_for_file: unnecessary_library_name

library desktop_app;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/controllers/home_node_controller.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart' show AppErrorCode, AppFailure;
import 'package:ssrvpn_shared/widgets/crash_report_prompt.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_screen.dart';
import 'screens/subscription_screen.dart';
import 'services/app_shutdown.dart';
import 'services/clash_service.dart' as clash;
import 'services/settings_service.dart';
import 'services/subscription_service.dart';
import 'services/tray_manager.dart';
import 'services/update_service.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_status.dart';
import 'startup/window_state_store.dart';
import 'theme/app_theme.dart';
import 'widgets/liquid_glass.dart';

part 'package:ssrvpn_shared/desktop_ui/desktop_app_shell_part.dart';

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

  SettingsService? _settingsService;
  clash.ClashService? _clashService;
  SubscriptionService? _subscriptionService;
  late final Future<bool> Function() _updateHandoffShutdown = _quitApp;

  @override
  void initState() {
    super.initState();
    UpdateService.onInstallerHandoff = _updateHandoffShutdown;
    StartupStatus.instance.addListener(_handleStartupStatusChanged);
    _handleStartupStatusChanged();
  }

  @override
  void dispose() {
    if (identical(
      UpdateService.onInstallerHandoff,
      _updateHandoffShutdown,
    )) {
      UpdateService.onInstallerHandoff = null;
    }
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
      unawaited(
        core.stop().catchError((Object error, StackTrace stack) {
          StartupLogger.error('Dispose core cleanup failed', error, stack);
        }),
      );
    }
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
      _clashService?.onRuntimeNotice = null;
      _clashService = nextClashService;
      _clashService!.addStatusListener(_handleCoreStatusChanged);
      _clashService!.onRuntimeNotice = (message) {
        unawaited(_presentRuntimeNotice(message));
      };
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

  Future<void> _handleTrayConnectToggle() async {
    final core = _clashService;
    final settings = _settingsService;
    if (core == null || settings == null) {
      await _presentTrayFailure('客户端仍在初始化，请稍后重试');
      return;
    }

    int? connectionGeneration;
    try {
      _clearRuntimeNotice();
      if (core.isRunning || core.connectionDesired) {
        core.requestConnectionIntent(false);
        await core.stop();
        return;
      }

      if (core.isStartupDisabled) {
        final reason = core.startupDisabledReason ?? '核心初始化失败';
        StartupLogger.warning(reason);
        await _presentTrayFailure(reason);
        return;
      }

      final rawYaml = _subscriptionService?.rawYaml;
      if (rawYaml == null || rawYaml.trim().isEmpty) {
        await _presentTrayFailure('请先添加并刷新订阅');
        return;
      }

      connectionGeneration = core.requestConnectionIntent(true);
      if (core.hasPendingSystemProxyRecovery) {
        final recovered = await core.recoverPendingSystemProxy();
        if (!core.isConnectionIntentCurrent(
          connectionGeneration,
          connected: true,
        )) {
          return;
        }
        if (!recovered) {
          core.requestConnectionIntent(false);
          final reason = core.lastStartError ?? '系统代理旧状态恢复失败';
          StartupLogger.writeDesktopFailureReportSync(
            'Tray connection failed: $reason',
          );
          await _presentTrayFailure(reason);
          return;
        }
      }

      final preferredNodeName = _defaultNodeName();
      final runtimeSettings = await core.prepareForStart(settings.settings);
      final portAdjustmentNotice = core.lastRuntimePortAdjustmentMessage;
      final config = core.generateClashConfig(
        rawYaml,
        runtimeSettings,
        preferredNodeName: preferredNodeName,
      );
      await core.writeConfig(config);
      if (!core.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        return;
      }
      final started = await core.start();
      if (!core.isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      )) {
        return;
      }
      if (!started) {
        core.requestConnectionIntent(false);
        final reason = core.lastStartError ?? '无法启动核心';
        if (AppFailure.fromMessage(reason).code ==
            AppErrorCode.permissionRequired) {
          StartupLogger.warning('Tray connection refused: $reason');
        } else {
          StartupLogger.writeDesktopFailureReportSync(
            'Tray connection failed: $reason',
          );
        }
        await _presentTrayFailure(reason);
        return;
      }
      if (started && preferredNodeName != null) {
        final switched = await core.switchSelectedProxy(preferredNodeName);
        if (switched &&
            core.isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            )) {
          await settings.updateLastSelectedNodeName(preferredNodeName);
        }
      }
      if (portAdjustmentNotice != null && portAdjustmentNotice.isNotEmpty) {
        await _presentRuntimeNotice(portAdjustmentNotice);
      }
    } catch (error, stack) {
      if (connectionGeneration != null &&
          core.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          )) {
        core.requestConnectionIntent(false);
      }
      StartupLogger.error('Tray connect toggle failed', error, stack);
      await _presentTrayFailure('托盘连接失败，请重试或查看日志');
      StartupLogger.writeDesktopFailureReportSync(
        'Tray connection failed',
        error: error,
        stack: stack,
      );
    } finally {
      await _trayManager.refreshMenu();
    }
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
        _clashService?.requestConnectionIntent(false);
        await _clashService?.stop();
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
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SSRVPN',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: CrashReportPrompt(
          child: _DesktopAppShell(
            isDark: true,
            safeMode: widget.startupFlags.safeMode,
            startupFailureMessages: StartupStatus.instance.failures
                .map((failure) => failure.userSummary)
                .toList(growable: false),
            runtimeNotice: _runtimeNotice,
            currentIndex: _currentIndex,
            onIndexChanged: (index) => setState(() => _currentIndex = index),
          ),
        ),
      ),
    );
  }

  Widget _buildStartupShell(StartupStatus status) {
    final failures = status.failures;
    final startupFailed = status.completed && !status.servicesReady;
    final requiresSecretRecovery =
        failures.any((failure) => failure.requiresWindowsSecretRecovery);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: CrashReportPrompt(
        child: Scaffold(
          backgroundColor: const Color(0xFF050508),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      startupFailed
                          ? Icons.error_outline_rounded
                          : Icons.shield_outlined,
                      color: startupFailed ? AppTheme.error : AppTheme.primary,
                      size: 42,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      startupFailed ? '启动失败' : 'SSRVPN',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: startupFailed
                            ? AppTheme.error
                            : AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      startupFailed
                          ? (requiresSecretRecovery
                              ? '本机密钥无法解密，请按下方步骤保留旧密文并恢复启动。'
                              : '初始化服务失败，请稍后查看诊断日志。')
                          : '正在加载必要组件...',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (!startupFailed) ...[
                      const SizedBox(height: 18),
                      SizedBox(
                        width: 260,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: _startupProgress(status),
                            minHeight: 6,
                            backgroundColor:
                                AppTheme.primary.withValues(alpha: 32 / 255),
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                    ],
                    if (failures.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _StartupProblemPanel(failures: failures),
                    ],
                  ],
                ),
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
              child: SelectableText(
                failure.userSummary,
                maxLines: failure.requiresWindowsSecretRecovery ? null : 2,
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

const _startupStepCount = 4;

double? _startupProgress(StartupStatus status) {
  if (status.completed) return 1;
  final finishedSteps = status.stepStates.values
      .where((state) => state == 'ok' || state == 'failed')
      .length;
  if (finishedSteps == 0 && status.currentStep == null) return null;
  final runningStep = status.currentStep == null ? 0 : 0.35;
  return ((finishedSteps + runningStep) / _startupStepCount).clamp(0.08, 0.95);
}
