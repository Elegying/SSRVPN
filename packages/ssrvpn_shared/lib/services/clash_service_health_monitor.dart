part of 'clash_service_base.dart';

final Object _healthMonitorEpochZoneKey = Object();
final Object _healthIntentZoneKey = Object();

mixin _ClashHealthSupport {
  int _healthMonitorEpoch = 0;
  int? _activeHealthCheckEpoch;

  int? captureAutomaticRestartIntent();
  http.Client? get apiClient;
  bool get hasLocalSmartRules;
  AppSettings get settings;
  String _apiUrl(String path);
  Map<String, String> apiHeaders({bool json = false});
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });
  void setLastHealthCheckError(String? value);

  // Android defers control-plane monitoring to its native service, so the
  // periodic control-plane monitor never runs there. This independent
  // low-frequency timer keeps the data plane observed on that platform too.
  Timer? _dataPlaneWatchTimer;

  @protected
  Duration get statusMonitorInterval => const Duration(seconds: 3);

  @protected
  int get maxConsecutiveHealthCheckFailures => 3;

  /// Recovery requires both repeated failures and elapsed time, and the two
  /// conditions must overlap instead of stacking.
  ///
  /// The failure threshold on its own already spans
  /// `maxConsecutiveHealthCheckFailures - 1` poll intervals (~6s at the 3s
  /// poll). The grace therefore has to stay strictly *inside* that span: tying
  /// it to the same two intervals makes both conditions land on the exact same
  /// millisecond, and a few milliseconds of timer jitter is then enough to
  /// withhold the trip and burn a whole extra poll cycle — a measured 9s
  /// window silently drifting to 12s. One interval keeps a comfortable margin,
  /// so the third consecutive failure always recovers at about 9s.
  @protected
  Duration get healthFailureGrace => statusMonitorInterval;

  /// Low-frequency data-plane observation used only where the periodic
  /// control-plane monitor is disabled (Android, where the native service owns
  /// it). Long enough to stay free, short enough that a node which stopped
  /// forwarding is reported within about a minute instead of never.
  @protected
  Duration get dataPlaneWatchInterval => const Duration(seconds: 60);

  bool get _canPublishHealthCheckResult {
    final monitorEpoch = Zone.current[_healthMonitorEpochZoneKey] as int?;
    final intent = Zone.current[_healthIntentZoneKey] as int?;
    return (monitorEpoch == null || monitorEpoch == _healthMonitorEpoch) &&
        (intent == null || intent == (captureAutomaticRestartIntent() ?? -1));
  }

  /// Verifies that the local core control API is reachable and responsive.
  Future<bool> healthCheck() async {
    final abort = Completer<void>();
    final endpoint = Uri.parse(_apiUrl('/version'));
    final headers = apiHeaders();
    try {
      final client = apiClient;
      if (client == null) return false;
      final versionRequest =
          http.AbortableRequest('GET', endpoint, abortTrigger: abort.future)
            ..headers.addAll(headers)
            ..followRedirects = false;
      final response = await client
          .send(versionRequest)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        if (hasLocalSmartRules) {
          final request = http.AbortableRequest(
              'GET', endpoint.replace(path: '/providers/rules'),
              abortTrigger: abort.future)
            ..headers.addAll(headers)
            ..followRedirects = false;
          final ready = await (() async {
            final reply = await client.send(request);
            if (reply.statusCode != 200) {
              await reply.stream.listen((_) {}).cancel();
              return null;
            }
            final bytes = BytesBuilder(copy: false);
            await for (final chunk in reply.stream) {
              if (bytes.length + chunk.length > 64 * 1024) return false;
              bytes.add(chunk);
            }
            final data = jsonDecode(utf8.decode(bytes.takeBytes()));
            final providers = data is Map ? data['providers'] : null;
            return providers is Map &&
                AppConstants.smartRuleProviderFiles.keys.every((name) {
                  final entry = providers[name];
                  return entry is Map &&
                      entry['ruleCount'] is int &&
                      (entry['ruleCount'] as int) > 0;
                });
          })()
              .timeout(const Duration(seconds: 2));
          if (ready != true) {
            setLastHealthCheckError(ready == false
                ? 'CORE_API_UNAVAILABLE: 分流规则尚未就绪'
                : 'CORE_API_UNAVAILABLE: 规则状态接口暂时不可用');
            return false;
          }
        }
        setLastHealthCheckError(null);
        return true;
      }
      setLastHealthCheckError(
        'CORE_API_UNAVAILABLE: API 返回 HTTP ${response.statusCode}，端口 ${endpoint.port}',
      );
      return false;
    } catch (error) {
      setLastHealthCheckError(
        'CORE_API_UNAVAILABLE: 本地控制服务暂时无法访问（端口 ${endpoint.port}）',
      );
      return false;
    } finally {
      // Future.timeout only stops waiting. Release the underlying request too,
      // so a stalled core cannot accumulate requests on each health check.
      abort.complete();
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
      setLastHealthCheckError('CORE_API_UNAVAILABLE: 运行状态检查超时');
      log(
        '运行状态检查超时 (${healthCheckTimeout.inSeconds}s)',
        level: RuntimeLogLevel.warning,
        event: 'health_check',
      );
      return false;
    } catch (error) {
      if (shouldPublish?.call() == false) return false;
      setLastHealthCheckError('CORE_API_UNAVAILABLE: 运行状态检查异常');
      log(
        '运行状态检查异常: cause=${safeRuntimeErrorCode(error)}',
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
    _startDataPlaneWatch();
    startNetworkChangeWatch();
    if (!enablePeriodicHealthMonitor) {
      _statusTimer = null;
      return;
    }
    final monitorEpoch = _healthMonitorEpoch;
    final monitorIntent = captureAutomaticRestartIntent();
    _statusTimer = Timer.periodic(statusMonitorInterval, (_) async {
      if (!_isRunning ||
          monitorEpoch != _healthMonitorEpoch ||
          monitorIntent != captureAutomaticRestartIntent() ||
          _activeHealthCheckEpoch == monitorEpoch) {
        return;
      }
      final checkIntent = captureAutomaticRestartIntent();
      _activeHealthCheckEpoch = monitorEpoch;
      var sourceSettled = false;
      final source = runZoned<Future<bool>>(
        () => Future<bool>.sync(healthCheck),
        zoneValues: {
          _healthMonitorEpochZoneKey: monitorEpoch,
          _healthIntentZoneKey: checkIntent ?? -1,
        },
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
        () =>
            monitorEpoch == _healthMonitorEpoch &&
            _isRunning &&
            checkIntent == captureAutomaticRestartIntent(),
      );
      if (monitorEpoch != _healthMonitorEpoch ||
          !_isRunning ||
          checkIntent != captureAutomaticRestartIntent()) {
        return;
      }
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
      final previousFailures = _healthFailures.failures;
      final shouldRecover = _healthFailures.observe(
        healthy: healthy,
        now: _healthClock.elapsed,
        grace: healthFailureGrace,
        suspensionGap: healthCheckTimeout + statusMonitorInterval * 3,
        threshold: maxConsecutiveHealthCheckFailures,
      );
      if (healthy) {
        if (previousFailures > 0) {
          this.log('连接状态已恢复正常，本次没有重启连接。', event: 'health_recovered');
        }
        scheduleDataPlaneObservation();
      } else if (_isRunning) {
        this.log(
          '运行状态检查失败 (${_healthFailures.failures}/'
          '$maxConsecutiveHealthCheckFailures): $_lastHealthCheckError '
          '[connection=${monitorIntent ?? 0}, API=$runtimeApiPort]',
          level: RuntimeLogLevel.warning,
          event: 'health_check',
        );
        if (_healthFailures.failures == 1) {
          this.log('连接状态暂时未通过检查，先保留连接并等待恢复。',
              level: RuntimeLogLevel.warning, event: 'health_recovery_wait');
        }
        if (shouldRecover) {
          final recoveryGeneration = captureAutomaticRestartIntent();
          stopStatusMonitor();
          final recoveryMonitorEpoch = _healthMonitorEpoch;
          _notifyStatusChanged();
          this.log(
            '运行状态持续异常，进入串行恢复',
            level: RuntimeLogLevel.warning,
            event: 'health_recovery',
          );
          var recovered = false;
          var recoverySuperseded = false;
          try {
            recovered = await runConnectionTransition(() async {
              var ownsRecoveryProgress = false;
              try {
                if (recoveryMonitorEpoch != _healthMonitorEpoch ||
                    recoveryGeneration != captureAutomaticRestartIntent()) {
                  recoverySuperseded = true;
                  // This queued recovery owns no replacement session. The
                  // newer transition alone decides what needs stopping.
                  return false;
                }
                if (recoveryGeneration == null) {
                  // A still-owned unhealthy runtime without a connect intent
                  // is cleaned up, but must never be automatically restarted.
                  await onStopRequired();
                  return false;
                }
                ownsRecoveryProgress = true;
                setAutoRecoveryInProgress(true);
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
              } finally {
                // Release the progress line before the serial queue admits a
                // replacement connection. The outer continuation may run only
                // after that replacement has already published its own step.
                if (ownsRecoveryProgress) setAutoRecoveryInProgress(false);
              }
            });
          } catch (error) {
            this.log(
              '运行状态异常后的恢复失败: '
              'cause=${safeRuntimeErrorCode(error)}',
              level: RuntimeLogLevel.error,
              event: 'health_recovery',
            );
          }
          final intentCurrent = recoveryGeneration != null &&
              isConnectionIntentCurrent(
                recoveryGeneration,
                connected: true,
              );
          // A newer queued transition may already have started by the time
          // this continuation runs. Do not publish old failure/status into it.
          if (recoverySuperseded || !intentCurrent) return;
          if (recovered && _isRunning) {
            _healthFailures.reset();
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

          if (_isRunning) {
            this.log(
              '自动恢复失败，平台仍报告核心或服务正在运行',
              level: RuntimeLogLevel.error,
              event: 'health_recovery',
            );
            notifyRuntimeNotice(
              const RuntimeNotice.error(
                '自动恢复失败，后台核心仍在运行且清理未完成，请点击断开重试',
              ),
            );
            _notifyStatusChanged();
            return;
          }
          markConnectionLost();
          notifyRuntimeNotice(
            const RuntimeNotice.error('连接已断开：自动恢复失败，请重新连接'),
          );
        }
      }
    });
  }

  void stopStatusMonitor() {
    _healthFailures.reset();
    _invalidateHealthMonitorSession();
    _statusTimer?.cancel();
    _statusTimer = null;
    _dataPlaneWatchTimer?.cancel();
    _dataPlaneWatchTimer = null;
    stopNetworkChangeWatch();
    if (_ruleProviderRefreshTimer?.isActive ?? false) {
      // A cancelled delay has not consumed this launch's one check yet.
      _ruleProviderRefreshScheduled = false;
    }
    _ruleProviderRefreshTimer?.cancel();
    _ruleProviderRefreshTimer = null;
  }

  /// Android hands control-plane monitoring to its native service, so the
  /// periodic monitor above never runs there. That left the data plane
  /// unobserved for the whole session: a node that stopped forwarding while the
  /// local control plane stayed healthy produced no warning at all, while the
  /// desktop platforms report it within about 30 seconds. Watch the data plane
  /// on an independent timer so every platform eventually notices.
  ///
  /// This only raises the advisory warning. It deliberately never restarts the
  /// core, matching the existing contract that data-plane failures are advisory.
  void _startDataPlaneWatch() {
    _dataPlaneWatchTimer?.cancel();
    _dataPlaneWatchTimer = null;
    if (enablePeriodicHealthMonitor) return;
    final watchEpoch = _healthMonitorEpoch;
    _dataPlaneWatchTimer = Timer.periodic(dataPlaneWatchInterval, (_) {
      if (!_isRunning || watchEpoch != _healthMonitorEpoch) return;
      scheduleDataPlaneObservation();
    });
  }

  void _scheduleRuleProviderRefreshOnce() {
    if (!_isRunning || _ruleProviderRefreshScheduled) return;
    _ruleProviderRefreshScheduled = true;
    _ruleProviderRefreshTimer = Timer(ruleProviderStartupRefreshDelay, () {
      _ruleProviderRefreshTimer = null;
      unawaited(refreshRuleProvidersOnce());
    });
  }
}
