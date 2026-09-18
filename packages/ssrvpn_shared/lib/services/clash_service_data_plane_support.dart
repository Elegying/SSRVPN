part of 'clash_service_base.dart';

final Object _dataPlaneObservationEpochZoneKey = Object();

/// Advisory node/internet state that is deliberately separate from the
/// process, service and runtime-configuration lifecycle.
mixin _ClashDataPlaneSupport {
  int _dataPlaneObservationEpoch = 0;
  final Stopwatch _dataPlaneObservationClock = Stopwatch()..start();
  Duration _dataPlaneObservationNotBefore = Duration.zero;
  int? _activeDataPlaneObservationEpoch;
  int? _coalescedDataPlaneObservationEpoch;
  String? _dataPlaneConnectivityWarning;
  String? _connectivityOwnershipWarning;

  bool get isRunning;
  AppSettings get settings;
  Future<String?> currentSelectedProxyName();
  bool get _canPublishHealthCheckResult;
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });
  void notifyStatusChanged();
  String _localHttpProxyConfig() => 'PROXY 127.0.0.1:${settings.proxyPort}';
  @visibleForTesting
  String userConnectivityProxyConfig() =>
      settings.enableTun ? 'DIRECT' : _localHttpProxyConfig();
  @protected
  // Two rounds of three bounded requests, including startup delay and gaps.
  Duration get dataPlaneObservationTimeout => const Duration(seconds: 60);

  @protected
  Future<http.StreamedResponse> startUserConnectivityRequest(
    http.Client client,
    Uri uri,
  ) =>
      client.send(http.Request('GET', uri));

  String? get connectivityWarning {
    final ownership = _connectivityOwnershipWarning;
    final dataPlane = _dataPlaneConnectivityWarning;
    if (ownership == null) return dataPlane;
    if (dataPlane == null || dataPlane == ownership) return ownership;
    return '$ownership\n$dataPlane';
  }

  @protected
  String? get connectivityOwnershipWarning => _connectivityOwnershipWarning;

  /// Advisory warning produced only by external route observations. Platform
  /// ownership warnings deliberately remain separate for diagnostics.
  @protected
  String? get dataPlaneConnectivityWarning => _dataPlaneConnectivityWarning;

  @protected
  bool get isDataPlaneObservationCurrent {
    final observationEpoch =
        Zone.current[_dataPlaneObservationEpochZoneKey] as int?;
    return observationEpoch == null ||
        observationEpoch == _dataPlaneObservationEpoch;
  }

  @protected
  Future<void> observeDataPlaneHealth() async {}

  @protected
  void setConnectivityWarning(String? value) {
    if (!_canPublishHealthCheckResult || !isDataPlaneObservationCurrent) {
      return;
    }
    if (_dataPlaneConnectivityWarning == value) return;
    final previous = connectivityWarning;
    _dataPlaneConnectivityWarning = value;
    if (connectivityWarning != previous) notifyStatusChanged();
  }

  @protected
  void setConnectivityOwnershipWarning(String? value) {
    if (!_canPublishHealthCheckResult) return;
    if (_connectivityOwnershipWarning == value) return;
    final previous = connectivityWarning;
    _connectivityOwnershipWarning = value;
    if (connectivityWarning != previous) notifyStatusChanged();
  }

  @protected
  void clearConnectivityWarningSilently() {
    _dataPlaneConnectivityWarning = null;
  }

  @protected
  void onDataPlaneObservationSessionReset() {}

  /// Invalidates observations that belong to the previously selected route.
  /// The connection remains live; one observation of the confirmed route is
  /// scheduled independently of the periodic control-plane monitor.
  @protected
  void onDataPlaneRouteChanged() {
    _dataPlaneObservationEpoch++;
    _coalescedDataPlaneObservationEpoch = null;
    onDataPlaneObservationSessionReset();
    clearConnectivityWarningSilently();
    if (isRunning) scheduleDataPlaneObservation();
  }

  void _resetDataPlaneObservationSession() {
    _dataPlaneObservationNotBefore = Duration.zero;
    _dataPlaneObservationEpoch++;
    _coalescedDataPlaneObservationEpoch = null;
    onDataPlaneObservationSessionReset();
    _dataPlaneConnectivityWarning = null;
    _connectivityOwnershipWarning = null;
  }

  @protected
  void scheduleDataPlaneObservation({
    bool rerunIfActive = false,
    Duration delay = Duration.zero,
  }) {
    final observationEpoch = _dataPlaneObservationEpoch;
    if (!isRunning) return;
    // Confirming the preferred node changes the route epoch during startup.
    // Keep the startup deadline across that change and periodic health ticks.
    final requestedStart = _dataPlaneObservationClock.elapsed + delay;
    if (delay > Duration.zero &&
        requestedStart > _dataPlaneObservationNotBefore) {
      _dataPlaneObservationNotBefore = requestedStart;
    }
    if (_activeDataPlaneObservationEpoch == observationEpoch) {
      if (rerunIfActive) {
        _coalescedDataPlaneObservationEpoch = observationEpoch;
      }
      return;
    }
    _activeDataPlaneObservationEpoch = observationEpoch;
    final observation = runZoned<Future<void>>(
      () async {
        final remaining =
            _dataPlaneObservationNotBefore - _dataPlaneObservationClock.elapsed;
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
        if (!isRunning || !isDataPlaneObservationCurrent) return;
        await observeDataPlaneHealth();
      },
      zoneValues: {_dataPlaneObservationEpochZoneKey: observationEpoch},
    );
    void finishObservation() {
      if (_activeDataPlaneObservationEpoch == observationEpoch) {
        _activeDataPlaneObservationEpoch = null;
      }
      if (_coalescedDataPlaneObservationEpoch == observationEpoch) {
        _coalescedDataPlaneObservationEpoch = null;
        scheduleDataPlaneObservation();
      }
    }

    // Future.timeout does not cancel its source. Keep the ownership flag until
    // the real probe settles so probes cannot overlap within one session.
    unawaited(
      observation.then<void>(
        (_) => finishObservation(),
        onError: (Object _, StackTrace __) => finishObservation(),
      ),
    );
    unawaited(
      observation
          .timeout(dataPlaneObservationTimeout)
          .catchError((Object error, StackTrace stack) {
        if (observationEpoch != _dataPlaneObservationEpoch || !isRunning) {
          return;
        }
        log(
          '数据通道观察失败，不影响核心生命周期: '
          'cause=${_safeRuntimeLogErrorCode(error)}',
          level: RuntimeLogLevel.warning,
          event: 'data_plane_probe',
        );
        setConnectivityWarning('数据通道检查未能完成，请稍后重试或切换节点');
      }),
    );
  }

  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    IOClient? client;
    if (request == null) {
      client = IOClient(
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..findProxy = (_) => userConnectivityProxyConfig(),
      );
    }
    final Future<int> Function(Uri uri) sendStatus;
    if (request != null) {
      sendStatus = (uri) async => (await request(uri)).statusCode;
    } else {
      sendStatus = (uri) => _sendUserConnectivityStatus(client!, uri);
    }
    final attempts = maxAttempts.clamp(1, 6).toInt();
    final endpointValues = settings.enableTun
        ? AppConstants.tunConnectivityTestUrls
        : AppConstants.systemProxyConnectivityTestUrls;
    final endpoints = endpointValues.map(Uri.parse).toList(growable: false);
    int? lastStatusCode;
    try {
      for (var attempt = 1; attempt <= attempts; attempt++) {
        if (shouldContinue?.call() == false) return null;
        try {
          // Rotate independent endpoints across retries so one blocked or
          // rate-limited service cannot define the entire data-plane state.
          final endpoint = endpoints[(attempt - 1) % endpoints.length];
          final statusCode = await sendStatus(endpoint);
          if (shouldContinue?.call() == false) return null;
          if (statusCode == 204 || statusCode == 200) {
            if (isRunning) setConnectivityWarning(null);
            return null;
          }
          lastStatusCode = statusCode;
          log(
            '外部网络验证 $attempt/$attempts 未通过：HTTP $statusCode；'
            '轮次=${(attempt - 1) ~/ endpoints.length + 1}；'
            '站点=${endpoints[(attempt - 1) % endpoints.length].host}；'
            '路径=${settings.enableTun ? 'TUN' : '本地代理'}，保留当前连接',
            event: 'data_plane_probe',
          );
        } catch (error) {
          if (shouldContinue?.call() == false) return null;
          lastStatusCode = null;
          log(
            '外部网络验证 $attempt/$attempts 未通过：'
            'cause=${_safeRuntimeLogErrorCode(error)}；'
            '轮次=${(attempt - 1) ~/ endpoints.length + 1}；'
            '站点=${endpoints[(attempt - 1) % endpoints.length].host}；'
            '路径=${settings.enableTun ? 'TUN' : '本地代理'}，保留当前连接',
            event: 'data_plane_probe',
          );
        }
        if (attempt < attempts && retryDelay > Duration.zero) {
          await Future<void>.delayed(retryDelay);
        }
      }
      if (shouldContinue?.call() == false) return null;
      late final String warning;
      if (lastStatusCode != null) {
        warning = '连接已建立，但多个外部网络验证端点均返回异常（最近 HTTP '
            '$lastStatusCode）；这可能是验证站点受限，不代表节点失效';
      } else {
        warning = '连接已建立，但暂时无法完成多个外部网络验证；'
            '这可能是验证站点受限，不代表节点失效';
      }
      if (isRunning) setConnectivityWarning(warning);
      return warning;
    } finally {
      client?.close();
    }
  }

  Future<int> _sendUserConnectivityStatus(
    http.Client client,
    Uri uri,
  ) async {
    const timeout = Duration(seconds: 6);
    final responseFuture = startUserConnectivityRequest(client, uri);
    late final http.StreamedResponse response;
    try {
      response = await responseFuture.timeout(timeout);
    } on TimeoutException {
      unawaited(
        responseFuture.then<void>(
          (lateResponse) => _cancelUserConnectivityBody(lateResponse.stream),
          onError: (Object _, StackTrace __) {},
        ),
      );
      rethrow;
    }

    final statusCode = response.statusCode;
    await _cancelUserConnectivityBody(response.stream);
    return statusCode;
  }

  Future<void> _cancelUserConnectivityBody(Stream<List<int>> stream) async {
    const cancellationTimeout = Duration(milliseconds: 50);
    try {
      final subscription = stream.listen(
        null,
        onError: (Object _) {},
        cancelOnError: true,
      );
      await subscription.cancel().timeout(cancellationTimeout);
    } catch (_) {
      // Connectivity verification only needs the response status. Closing the
      // owning client in the caller remains the fallback if cancellation fails.
    }
  }

  /// Exit cache attribution must fail closed on an unreadable GLOBAL group,
  /// instead of using the display-oriented selection method's PROXY fallback.
  bool get _exitObservationHasManualDirectOverride {
    bool matches(String site, String host) {
      final domain = AppSettings.extractForceProxyHost(site);
      return domain != null && (host == domain || host.endsWith('.$domain'));
    }

    return [
      PublicIpInfoService.ipv4Endpoint,
      PublicIpInfoService.fallbackEndpoint
    ].any((endpoint) =>
        !settings.forceProxySites.any((site) => matches(site, endpoint.host)) &&
        settings.forceDirectSites.any((site) => matches(site, endpoint.host)));
  }

  Future<String?> confirmedProxyExitNode() async {
    if (_exitObservationHasManualDirectOverride) return null;
    return currentSelectedProxyName();
  }

  Future<PublicIpInfo> fetchCurrentPublicIpInfo() async {
    if (_exitObservationHasManualDirectOverride) {
      throw const PublicIpInfoException('手动直连规则覆盖出口查询，暂停节点出口归属');
    }
    final client = IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (_) => _localHttpProxyConfig(),
    );
    final elapsed = Stopwatch()..start();
    try {
      final info = await PublicIpInfoService(client: client).fetch();
      log('公网 IP 查询已完成，耗时 ${elapsed.elapsedMilliseconds}ms',
          event: 'public_ip');
      return info;
    } catch (error) {
      log(
          '公网 IP 查询暂未完成：cause=${_safeRuntimeLogErrorCode(error)}；'
          '耗时 ${elapsed.elapsedMilliseconds}ms；不改变当前连接',
          event: 'public_ip');
      rethrow;
    } finally {
      client.close();
    }
  }

  String? normalizeCountryCode(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) return null;
    if (code == 'UK') return 'GB';
    if (code == 'EL') return 'GR';
    return code;
  }
}
