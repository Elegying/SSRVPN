part of 'app.dart';

mixin _MacosAppRuntimeActions on State<SSRVpnApp> {
  final TrayManager _trayManager = TrayManager();

  int _currentIndex = 0;
  bool _isQuitting = false;
  RuntimeNotice? _runtimeNotice;
  bool _lastObservedCoreRunning = false;
  bool _runtimeNoticeTracksPendingRecovery = false;
  Timer? _runtimeNoticeAutoClearTimer;

  SettingsService? _settingsService;
  clash.ClashService? _clashService;
  SubscriptionService? _subscriptionService;

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
    if (_isQuitting) return;
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
        core.interruptPendingStart();
        await core.runConnectionTransition(core.stop);
        return;
      }

      if (core.hasPendingSystemProxyRecovery &&
          !await core.recoverPendingSystemProxy()) {
        final reason = core.lastStartError ?? '系统代理旧状态恢复失败';
        StartupLogger.warning(reason);
        await _presentTrayFailure(reason);
        return;
      }
      if (core.isStartupDisabled) {
        final reason = core.startupDisabledReason ?? '核心初始化失败';
        StartupLogger.warning(reason);
        await _presentTrayFailure(reason);
        return;
      }

      final subscriptionService = _subscriptionService;
      final rawYaml = subscriptionService?.rawYaml;
      if (rawYaml == null || rawYaml.trim().isEmpty) {
        await _presentTrayFailure('请先添加并刷新订阅');
        return;
      }
      final subscriptionRevision = subscriptionService!.revision;

      connectionGeneration = core.requestConnectionIntent(true);
      final preferredNodeName = _defaultNodeName();
      final connectionResult = await core.runConnectionTransition(
        () => const DesktopConnectionCoordinator().connect(
          preferredSettings: settings.settings,
          prepareForStart: core.prepareForStart,
          generateConfig: (runtimeSettings) => core.generateClashConfigAsync(
            rawYaml,
            runtimeSettings,
            preferredNodeName: preferredNodeName,
          ),
          writeConfig: core.writeConfig,
          start: core.start,
          stop: core.stop,
          isRevisionCurrent: () =>
              identical(_subscriptionService, subscriptionService) &&
              subscriptionService.revision == subscriptionRevision,
          isIntentCurrent: () => core.isConnectionIntentCurrent(
            connectionGeneration!,
            connected: true,
          ),
          shouldRollbackStaleIntent: () => !core.connectionDesired,
          cancelIntent: () {
            core.requestConnectionIntent(false);
            core.interruptPendingStart();
          },
          readStartFailureReason: () => core.lastStartError,
          readRuntimeNotice: () => core.lastRuntimePortAdjustmentMessage,
          switchPreferredNode: preferredNodeName == null
              ? null
              : () => core.switchSelectedProxy(preferredNodeName),
        ),
      );
      if (connectionResult.failure == DesktopConnectionFailure.cancelled) {
        return;
      }
      if (connectionResult.failure ==
          DesktopConnectionFailure.subscriptionChanged) {
        throw StateError(
          connectionResult.failureReason ?? desktopSubscriptionChangedMessage,
        );
      }
      if (!connectionResult.connected) {
        await _presentTrayFailure(
          connectionResult.failureReason ?? '无法启动核心',
        );
        return;
      }
      if (core.isRunning &&
          core.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          )) {
        core.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: settings.settings,
          generateConfig: (runtimeSettings, recoveryNodeName) =>
              core.generateClashConfigAsync(
            rawYaml,
            runtimeSettings,
            preferredNodeName: recoveryNodeName,
          ),
          isRevisionCurrent: () =>
              subscriptionService.revision == subscriptionRevision &&
              subscriptionService.rawYaml == rawYaml,
          preferredNodeName: preferredNodeName,
        );
      }
      if (preferredNodeName != null &&
          connectionResult.preferredNodeSwitchSucceeded == true &&
          core.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          )) {
        try {
          await settings.updateLastSelectedNodeName(preferredNodeName);
        } catch (error, stack) {
          StartupLogger.error(
            'Persisting tray-selected node failed',
            error,
            stack,
          );
        }
      }
      final preferredNodeWarning = connectionResult.preferredNodeSwitchWarning(
        preferredNodeName: preferredNodeName,
      );
      final portAdjustmentNotice = connectionResult.runtimeNotice;
      if (preferredNodeWarning != null) {
        await _presentRuntimeNotice(
          RuntimeNotice.warning(preferredNodeWarning),
        );
      } else if (portAdjustmentNotice != null &&
          portAdjustmentNotice.isNotEmpty) {
        await _presentRuntimeNotice(
          RuntimeNotice.success(portAdjustmentNotice),
        );
      }
    } catch (error, stack) {
      final isCurrent = connectionGeneration != null &&
          core.isConnectionIntentCurrent(
            connectionGeneration,
            connected: true,
          );
      if (!isCurrent && core.connectionDesired) return;
      if (isCurrent) {
        core.requestConnectionIntent(false);
        core.interruptPendingStart();
      }
      StartupLogger.error('Tray connect toggle failed', error, stack);
      await _presentTrayFailure(error);
    } finally {
      await _trayManager.refreshMenu();
    }
  }

  String? _defaultNodeName() {
    final nodes = _subscriptionService?.allNodes ?? const [];
    final remembered = _settingsService?.settings.lastSelectedNodeName;
    return HomeNodeController.resolveDefaultNodeFrom(nodes, remembered)?.name;
  }

  Future<void> _presentTrayFailure(Object? reason) => _presentRuntimeNotice(
        RuntimeNotice.error(safeUserFacingFailureMessage(reason)),
      );

  Future<void> _presentRuntimeNotice(
    RuntimeNotice notice, {
    bool tracksPendingRecovery = false,
  }) async {
    _runtimeNoticeAutoClearTimer?.cancel();
    _runtimeNoticeAutoClearTimer = null;
    if (mounted) {
      setState(() {
        _runtimeNotice = notice;
        _runtimeNoticeTracksPendingRecovery = tracksPendingRecovery;
        _currentIndex = 0;
      });
      _runtimeNoticeAutoClearTimer = scheduleSuccessfulRuntimeNoticeClear(
        notice: notice,
        currentNotice: () => _runtimeNotice,
        clear: _clearRuntimeNotice,
      );
    }
    unawaited(_refreshTrayStatus());
    try {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (error, stack) {
      StartupLogger.error('Present macOS runtime notice failed', error, stack);
    }
  }

  void _clearRuntimeNotice() {
    _runtimeNoticeAutoClearTimer?.cancel();
    _runtimeNoticeAutoClearTimer = null;
    _runtimeNoticeTracksPendingRecovery = false;
    if (mounted && _runtimeNotice != null) {
      setState(() => _runtimeNotice = null);
    }
    unawaited(_refreshTrayStatus());
  }

  Future<void> _refreshTrayStatus() async {
    final core = _clashService;
    final connected = core?.isRunning ?? false;
    final port =
        core?.runtimeProxyPort ?? _settingsService?.settings.proxyPort ?? 7890;
    final notice = _runtimeNotice;
    final tooltip = notice != null
        ? 'SSRVPN · ${notice.message.length <= 90 ? notice.message : '${notice.message.substring(0, 90)}…'}'
        : connected
            ? 'SSRVPN · 已连接 · HTTP 127.0.0.1:$port'
            : 'SSRVPN · 未连接';
    await _trayManager.refreshMenu();
    await _trayManager.setToolTip(tooltip);
  }

  Future<bool> _quitApp() async {
    if (_isQuitting) return false;
    _isQuitting = true;
    final failures = await runMacosAppShutdown(
      flushSettings: () async => _settingsService?.flush(),
      stopCore: () async {
        final core = _clashService;
        if (core == null) return;
        core.requestConnectionIntent(false);
        core.interruptPendingStart();
        try {
          await core.runConnectionTransition(core.stopForAppShutdown);
        } finally {
          await core.flushLogs();
        }
      },
      allowWindowClose: () => windowManager.setPreventClose(false),
      destroyWindow: windowManager.destroy,
      destroyTray: _trayManager.destroy,
    );
    for (final failure in failures) {
      StartupLogger.error(
        'Quit cleanup step ${failure.step} failed',
        failure.error,
        failure.stackTrace,
      );
    }
    if (!isMacosAppShutdownSafeToExit(failures)) {
      _isQuitting = false;
      final failure = failures.firstWhere(
        (value) => value.step == macosShutdownStopCoreStep,
      );
      final reason = failure.error
          .toString()
          .replaceFirst('Bad state: ', '')
          .replaceFirst('StateError: ', '');
      final message = safeUserFacingFailureWithAction(
        reason,
        '窗口和菜单栏图标已保留，请稍后重试退出。',
      );
      await _presentRuntimeNotice(
        RuntimeNotice.error('退出未完成：$message'),
      );
      return false;
    }
    SystemNavigator.pop();
    return true;
  }
}
