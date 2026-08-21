part of 'clash_service_base.dart';

final Object _healthMonitorEpochZoneKey = Object();

mixin _ClashHealthSupport {
  int _healthMonitorEpoch = 0;
  int? _activeHealthCheckEpoch;

  http.Client? get apiClient;
  AppSettings get settings;
  String _apiUrl(String path);
  Map<String, String> apiHeaders({bool json = false});
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });
  void setLastHealthCheckError(String? value);

  bool get _canPublishHealthCheckResult {
    final monitorEpoch = Zone.current[_healthMonitorEpochZoneKey] as int?;
    return monitorEpoch == null || monitorEpoch == _healthMonitorEpoch;
  }

  /// Verifies that the local core control API is reachable and responsive.
  Future<bool> healthCheck() async {
    try {
      final client = apiClient;
      if (client == null) return false;
      final response = await client
          .get(Uri.parse(_apiUrl('/version')), headers: apiHeaders())
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        setLastHealthCheckError(null);
        return true;
      }
      setLastHealthCheckError(
        'API 返回 HTTP ${response.statusCode}，端口 ${settings.apiPort}',
      );
      return false;
    } catch (error) {
      setLastHealthCheckError(
        '无法连接 127.0.0.1:${settings.apiPort} ($error)',
      );
      return false;
    }
  }

  @protected
  Duration get healthCheckTimeout => const Duration(seconds: 10);

  @protected
  Future<bool> boundedHealthCheck([
    Future<bool>? source,
    bool Function()? shouldPublish,
  ]) async {
    try {
      return await (source ?? Future<bool>.sync(healthCheck))
          .timeout(healthCheckTimeout);
    } on TimeoutException {
      if (shouldPublish?.call() == false) return false;
      setLastHealthCheckError('运行状态检查超时');
      log(
        '运行状态检查超时 (${healthCheckTimeout.inSeconds}s)',
        level: RuntimeLogLevel.warning,
        event: 'health_check',
      );
      return false;
    } catch (error) {
      if (shouldPublish?.call() == false) return false;
      setLastHealthCheckError('运行状态检查异常');
      log(
        '运行状态检查异常: $error',
        level: RuntimeLogLevel.warning,
        event: 'health_check',
      );
      return false;
    }
  }

  @protected
  void onPeriodicHealthCheckResult(bool healthy) {}

  void _invalidateHealthMonitorSession() {
    _healthMonitorEpoch++;
  }
}

extension ClashServiceHealthMonitor on ClashServiceBase {
  void startStatusMonitor() {
    _statusTimer?.cancel();
    _scheduleRuleProviderRefreshOnce();
    if (!enablePeriodicHealthMonitor) {
      _statusTimer = null;
      return;
    }
    final monitorEpoch = _healthMonitorEpoch;
    _statusTimer = Timer.periodic(statusMonitorInterval, (_) async {
      if (!_isRunning ||
          monitorEpoch != _healthMonitorEpoch ||
          _activeHealthCheckEpoch == monitorEpoch) {
        return;
      }
      _activeHealthCheckEpoch = monitorEpoch;
      var sourceSettled = false;
      final source = runZoned<Future<bool>>(
        () => Future<bool>.sync(healthCheck),
        zoneValues: {_healthMonitorEpochZoneKey: monitorEpoch},
      );
      unawaited(
        source.then<void>(
          (_) {
            sourceSettled = true;
            if (_activeHealthCheckEpoch == monitorEpoch) {
              _activeHealthCheckEpoch = null;
            }
          },
          onError: (Object _, StackTrace __) {
            sourceSettled = true;
            if (_activeHealthCheckEpoch == monitorEpoch) {
              _activeHealthCheckEpoch = null;
            }
          },
        ),
      );
      final healthy = await boundedHealthCheck(
        source,
        () => monitorEpoch == _healthMonitorEpoch && _isRunning,
      );
      if (monitorEpoch != _healthMonitorEpoch || !_isRunning) return;
      if (!sourceSettled) {
        // An unknown interval is not a stable healthy interval. Platforms may
        // use this hook to restart a recovery-budget cooldown without treating
        // the observation timeout itself as a lifecycle failure.
        onPeriodicHealthCheckResult(false);
        this.log(
          '运行状态检查观察超时；底层检查尚未结束，本轮不累计失败',
          level: RuntimeLogLevel.warning,
          event: 'health_check',
        );
        return;
      }
      onPeriodicHealthCheckResult(healthy);
      if (healthy) {
        _consecutiveHealthCheckFailures = 0;
        scheduleDataPlaneObservation();
      } else if (_isRunning) {
        _consecutiveHealthCheckFailures++;
        this.log(
          '运行状态检查失败 ($_consecutiveHealthCheckFailures/'
          '$maxConsecutiveHealthCheckFailures): $_lastHealthCheckError',
          level: RuntimeLogLevel.warning,
          event: 'health_check',
        );
        if (_consecutiveHealthCheckFailures >=
            maxConsecutiveHealthCheckFailures) {
          final recoveryGeneration = captureAutomaticRestartIntent();
          stopStatusMonitor();
          _notifyStatusChanged();
          this.log(
            '运行状态持续异常，进入串行恢复',
            level: RuntimeLogLevel.warning,
            event: 'health_recovery',
          );
          var recovered = false;
          try {
            recovered = await runConnectionTransition(() async {
              try {
                if (recoveryGeneration == null ||
                    !isConnectionIntentCurrent(
                      recoveryGeneration,
                      connected: true,
                    )) {
                  await onStopRequired();
                  return false;
                }
                notifyRuntimeNotice(
                  const RuntimeNotice.progress(
                    '运行状态暂时异常，正在自动恢复连接…',
                  ),
                );
                final platformRecovered =
                    await recoverAfterHealthCheckFailure(recoveryGeneration);
                final intentStillCurrent = isConnectionIntentCurrent(
                  recoveryGeneration,
                  connected: true,
                );
                if ((!platformRecovered || !intentStillCurrent) && _isRunning) {
                  await onStopRequired();
                }
                return platformRecovered && intentStillCurrent;
              } catch (_) {
                if (_isRunning) {
                  try {
                    await onStopRequired();
                  } catch (_) {}
                }
                rethrow;
              }
            });
          } catch (error) {
            this.log(
              '运行状态异常后的恢复失败: $error',
              level: RuntimeLogLevel.error,
              event: 'health_recovery',
            );
          }

          var intentCurrent = recoveryGeneration != null &&
              isConnectionIntentCurrent(
                recoveryGeneration,
                connected: true,
              );
          if (recovered && intentCurrent && _isRunning) {
            _consecutiveHealthCheckFailures = 0;
            this.log(
              '连接运行状态已自动恢复',
              event: 'health_recovery',
            );
            notifyRuntimeNotice(
              const RuntimeNotice.success('连接已自动恢复'),
            );
            startStatusMonitor();
            return;
          }

          intentCurrent = recoveryGeneration != null &&
              isConnectionIntentCurrent(
                recoveryGeneration,
                connected: true,
              );
          if (_isRunning) {
            this.log(
              '自动恢复失败，平台仍报告核心或服务正在运行',
              level: RuntimeLogLevel.error,
              event: 'health_recovery',
            );
            notifyRuntimeNotice(
              RuntimeNotice.error(
                intentCurrent
                    ? '自动恢复失败，后台核心仍在运行且清理未完成，请点击断开重试'
                    : '断开尚未完成，后台核心仍在运行，请再次点击断开',
              ),
            );
            _notifyStatusChanged();
            return;
          }
          if (intentCurrent) {
            markConnectionLost();
            notifyRuntimeNotice(
              const RuntimeNotice.error(
                '连接已断开：自动恢复失败，请重新连接',
              ),
            );
          } else {
            setRunning(false);
            _notifyStatusChanged();
          }
        }
      }
    });
  }

  void stopStatusMonitor() {
    _invalidateHealthMonitorSession();
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
