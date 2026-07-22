part of 'clash_service_base.dart';

extension ClashServiceHealthMonitor on ClashServiceBase {
  void startStatusMonitor() {
    _statusTimer?.cancel();
    _scheduleRuleProviderRefreshOnce();
    if (!enablePeriodicHealthMonitor) {
      _statusTimer = null;
      return;
    }
    _statusTimer = Timer.periodic(statusMonitorInterval, (_) async {
      if (!_isRunning || _healthCheckInProgress) return;
      _healthCheckInProgress = true;
      try {
        final healthy = await healthCheck();
        if (healthy) {
          _consecutiveHealthCheckFailures = 0;
          scheduleDataPlaneObservation();
        } else if (_isRunning) {
          _consecutiveHealthCheckFailures++;
          this.log(
            'Mihomo 健康检查失败 ($_consecutiveHealthCheckFailures/'
            '$maxConsecutiveHealthCheckFailures): $_lastHealthCheckError',
          );
          if (_consecutiveHealthCheckFailures >=
              maxConsecutiveHealthCheckFailures) {
            final recoveryGeneration = captureAutomaticRestartIntent();
            stopStatusMonitor();
            _notifyStatusChanged();
            this.log('Mihomo 控制面持续失联，进入串行恢复');
            if (recoveryGeneration != null &&
                isConnectionIntentCurrent(
                  recoveryGeneration,
                  connected: true,
                )) {
              notifyRuntimeNotice('Mihomo 暂时失去响应，正在自动恢复连接…');
            }
            var recovered = false;
            try {
              recovered = await runConnectionTransition(() async {
                if (recoveryGeneration == null ||
                    !isConnectionIntentCurrent(
                      recoveryGeneration,
                      connected: true,
                    )) {
                  await onStopRequired();
                  return false;
                }
                return recoverAfterHealthCheckFailure(recoveryGeneration);
              });
            } catch (error) {
              this.log('Mihomo 失联后的恢复失败: $error');
            }

            var intentCurrent = recoveryGeneration != null &&
                isConnectionIntentCurrent(
                  recoveryGeneration,
                  connected: true,
                );
            if (recovered && intentCurrent && _isRunning) {
              _consecutiveHealthCheckFailures = 0;
              this.log('Mihomo 连接已自动恢复');
              notifyRuntimeNotice('连接已自动恢复');
              startStatusMonitor();
              return;
            }

            // A disconnect or quit may win while recovery is in flight. If a
            // late platform restart nevertheless succeeded, stop it before
            // publishing the final state.
            if (_isRunning) {
              try {
                await runConnectionTransition(onStopRequired);
              } catch (error) {
                this.log('取消过期自动恢复时停止核心失败: $error');
              }
            }
            intentCurrent = recoveryGeneration != null &&
                isConnectionIntentCurrent(
                  recoveryGeneration,
                  connected: true,
                );
            if (_isRunning) {
              this.log('Mihomo 自动恢复失败，平台仍报告核心或服务正在运行');
              notifyRuntimeNotice(
                intentCurrent
                    ? '自动恢复失败，后台核心仍在运行且清理未完成，请点击断开重试'
                    : '断开尚未完成，后台核心仍在运行，请再次点击断开',
              );
              _notifyStatusChanged();
              return;
            }
            if (intentCurrent) {
              markConnectionLost();
              notifyRuntimeNotice('连接已断开：Mihomo 自动恢复失败，请重新连接');
            } else {
              setRunning(false);
              _notifyStatusChanged();
            }
          }
        }
      } finally {
        _healthCheckInProgress = false;
      }
    });
  }

  void stopStatusMonitor() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _ruleProviderRefreshTimer?.cancel();
    _ruleProviderRefreshTimer = null;
  }

  void _scheduleRuleProviderRefreshOnce() {
    _ruleProviderRefreshTimer?.cancel();
    if (!_isRunning) return;
    _ruleProviderRefreshTimer = Timer(ruleProviderStartupRefreshDelay, () {
      _ruleProviderRefreshTimer = null;
      unawaited(refreshRuleProvidersOnce());
    });
  }
}
