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
        '运行状态检查异常: cause=${_safeRuntimeLogErrorCode(error)}',
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
      if (healthy) {
        _consecutiveHealthCheckFailures = 0;
        scheduleDataPlaneObservation();
      } else if (_isRunning) {
        _consecutiveHealthCheckFailures++;
        this.log(
          '运行状态检查失败 ($_consecutiveHealthCheckFailures/'
          '$maxConsecutiveHealthCheckFailures): $_lastHealthCheckError '
          '[connection=${monitorIntent ?? 0}, API=$runtimeApiPort]',
          level: RuntimeLogLevel.warning,
          event: 'health_check',
        );
        if (_consecutiveHealthCheckFailures >=
            maxConsecutiveHealthCheckFailures) {
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
              '运行状态异常后的恢复失败: '
              'cause=${_safeRuntimeLogErrorCode(error)}',
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
    _invalidateHealthMonitorSession();
    _statusTimer?.cancel();
    _statusTimer = null;
    if (_ruleProviderRefreshTimer?.isActive ?? false) {
      // A cancelled delay has not consumed this launch's one check yet.
      _ruleProviderRefreshScheduled = false;
    }
    _ruleProviderRefreshTimer?.cancel();
    _ruleProviderRefreshTimer = null;
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
