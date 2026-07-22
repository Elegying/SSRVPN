part of 'app.dart';

extension _WindowsAppRuntimeActions on _SSRVpnAppState {
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
          core.interruptPendingStart();
          final reason = core.lastStartError ?? '系统代理旧状态恢复失败';
          StartupLogger.writeDesktopFailureReportSync(
            'Tray connection failed: $reason',
          );
          await _presentTrayFailure(reason);
          return;
        }
      }

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
        final reason = connectionResult.failureReason ?? '无法启动核心';
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
      final portAdjustmentNotice = connectionResult.runtimeNotice;
      if (portAdjustmentNotice != null && portAdjustmentNotice.isNotEmpty) {
        await _presentRuntimeNotice(portAdjustmentNotice);
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
      final reason = error
          .toString()
          .replaceFirst('Bad state: ', '')
          .replaceFirst('Exception: ', '');
      await _presentTrayFailure(
        reason.startsWith('订阅已更新') ? reason : '托盘连接失败，请重试或查看日志',
      );
      StartupLogger.writeDesktopFailureReportSync(
        'Tray connection failed',
        error: error,
        stack: stack,
      );
    } finally {
      await _trayManager.refreshMenu();
    }
  }
}
