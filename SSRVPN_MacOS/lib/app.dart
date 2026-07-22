// ignore_for_file: unnecessary_library_name

library desktop_app;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/controllers/home_node_controller.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show
        AppConstants,
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
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';
import 'startup/startup_orchestrator.dart';
import 'startup/startup_status.dart';
import 'startup/window_state_store.dart';
import 'theme/app_theme.dart';

part 'package:ssrvpn_shared/desktop_ui/desktop_app_shell_part.dart';
part 'app_runtime_actions_part.dart';

class SSRVpnApp extends StatefulWidget {
  const SSRVpnApp({super.key, required this.startupFlags});

  final StartupFlags startupFlags;

  @override
  State<SSRVpnApp> createState() => _SSRVpnAppState();
}

class _SSRVpnAppState extends State<SSRVpnApp>
    with WindowListener, _MacosAppRuntimeActions {
  bool _windowListenerAttached = false;
  Timer? _windowStateSaveDebounce;
  bool _startupRetryInProgress = false;

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
    _clashService?.onProcessExit = null;
    _clashService?.onRuntimeNotice = null;
    final core = _clashService;
    if (core != null && !_isQuitting) {
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
      _clashService?.onProcessExit = null;
      _clashService?.onRuntimeNotice = null;
      _clashService = nextClashService;
      _clashService!.addStatusListener(_handleCoreStatusChanged);
      _clashService!.onRuntimeNotice = (message) {
        unawaited(_presentRuntimeNotice(message));
      };
      _clashService!.onProcessExit = () {
        final notice = _clashService?.lastUnexpectedExitNotice ??
            'Mihomo 异常退出，系统代理恢复结果未知。请点击首页“连接”重试。';
        unawaited(_presentRuntimeNotice(notice));
      };
      _configureTrayCallbacks();
      final recoveryNotice = _clashService!.startupRecoveryNotice;
      if (recoveryNotice != null) {
        unawaited(
          _presentRuntimeNotice(
            recoveryNotice,
            tracksPendingRecovery: true,
          ),
        );
      }
    }

    _settingsService = status.settingsService;
    _subscriptionService = nextSubscriptionService;

    if (mounted) setState(() {});
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

  Future<void> _retryCoreInitialization() async {
    if (_startupRetryInProgress) return;
    setState(() => _startupRetryInProgress = true);
    try {
      await StartupOrchestrator(widget.startupFlags).retryCoreInitialization();
    } finally {
      if (mounted) setState(() => _startupRetryInProgress = false);
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
            safeMode: widget.startupFlags.safeMode,
            startupFailureMessages: StartupStatus.instance.failures
                .map(_startupFailureSummary)
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        backgroundColor: const Color(0xFF050508),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final minContentHeight =
                  constraints.maxHeight > 64 ? constraints.maxHeight - 64 : 0.0;
              return SingleChildScrollView(
                key: const Key('macos-startup-shell-scroll'),
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minContentHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            startupFailed
                                ? Icons.error_outline_rounded
                                : Icons.shield_outlined,
                            color: startupFailed
                                ? AppTheme.error
                                : AppTheme.primary,
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
                                ? '初始化服务失败，请稍后查看诊断日志。'
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
                                  backgroundColor: AppTheme.primary
                                      .withValues(alpha: 32 / 255),
                                  color: AppTheme.primary,
                                ),
                              ),
                            ),
                          ],
                          if (failures.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            _StartupProblemPanel(failures: failures),
                          ],
                          if (startupFailed) ...[
                            const SizedBox(height: 16),
                            FilledButton(
                              key: const Key('macos-startup-retry-button'),
                              onPressed: _startupRetryInProgress
                                  ? null
                                  : _retryCoreInitialization,
                              child: Text(
                                _startupRetryInProgress ? '正在重试…' : '重试初始化',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
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
                _startupFailureSummary(failure),
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

String _startupFailureSummary(StartupFailure failure) {
  switch (failure.step) {
    case 'window_manager':
      return '窗口组件初始化失败，请尝试安全模式启动。';
    case 'screen_retriever':
      return '显示器信息读取失败，应用会继续尝试打开。';
    case 'system_tray':
      return '系统托盘初始化失败，应用会继续尝试打开。';
    case 'mihomo_core':
      return '核心服务初始化失败，请稍后查看诊断日志。';
    default:
      return '启动组件初始化失败，应用会继续尝试打开。';
  }
}
