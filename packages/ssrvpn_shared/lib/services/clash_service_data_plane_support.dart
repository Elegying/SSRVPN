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
  Timer? _networkChangeWatchTimer;
  String? _networkFingerprint;
  bool _networkCheckInFlight = false;

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

  /// 最近一次数据面观察完成的时间；null 表示本次会话尚未完成过观察。
  ///
  /// 诊断页读的是缓存告警，而不是重新探测——完整探测最坏约 41 秒，塞不进
  /// `diagnosticCheckTimeout`（10 秒）的预算。既然无法在诊断时刷新，
  /// 就必须把观察时间一并说出来，否则用户无法判断「暂未通过」是当前状态
  /// 还是几十秒前的旧状态。平台没有独立时间戳时保持 null。
  @protected
  DateTime? get dataPlaneObservationAt => null;

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
          'cause=${safeRuntimeErrorCode(error)}',
          level: RuntimeLogLevel.warning,
          event: 'data_plane_probe',
        );
        setConnectivityWarning('数据通道检查未能完成，请稍后重试或切换节点');
      }),
    );
  }

  /// How often the physical interface fingerprint is compared.
  ///
  /// The local control API lives on 127.0.0.1, so switching from Wi-Fi to
  /// Ethernet leaves it perfectly healthy while the real path is gone. Without
  /// a watch, the user sat on "connected but unusable" for up to ~70s waiting
  /// for the platform's own observation throttle to expire. Comparing the
  /// interface set lets a physical change invalidate that observation at once.
  ///
  /// Null disables the watch where the platform already reports changes itself.
  @protected
  Duration? get networkChangeWatchInterval => const Duration(seconds: 10);

  @protected
  void startNetworkChangeWatch() {
    _networkChangeWatchTimer?.cancel();
    _networkChangeWatchTimer = null;
    final interval = networkChangeWatchInterval;
    if (interval == null) return;
    _networkChangeWatchTimer = Timer.periodic(interval, (_) {
      unawaited(_checkNetworkChange());
    });
  }

  @protected
  void stopNetworkChangeWatch() {
    _networkChangeWatchTimer?.cancel();
    _networkChangeWatchTimer = null;
    _networkFingerprint = null;
  }

  Future<void> _checkNetworkChange() async {
    if (_networkCheckInFlight || !isRunning) return;
    _networkCheckInFlight = true;
    try {
      final String fingerprint;
      try {
        final interfaces = await NetworkInterface.list(
            includeLoopback: false, includeLinkLocal: false);
        final parts = <String>[];
        for (final interface in interfaces) {
          final addresses = interface.addresses
              .map((entry) => entry.address)
              .toList()
            ..sort();
          parts.add('${interface.name}:${addresses.join(',')}');
        }
        parts.sort();
        fingerprint = parts.join('|');
      } catch (error) {
        // Enumeration is best-effort. A failure must not disturb any state,
        // and must not be mistaken for a change on the next comparison.
        return;
      }
      final previous = _networkFingerprint;
      _networkFingerprint = fingerprint;
      if (previous == null || previous == fingerprint) return;
      log(
        '物理网络发生变化，立即重新观察数据通道',
        event: 'data_plane_probe',
      );
      onDataPlaneObservationSessionReset();
      scheduleDataPlaneObservation(rerunIfActive: true);
    } finally {
      _networkCheckInFlight = false;
    }
  }

  Future<String?> verifyUserConnectivity({
    int maxAttempts = AppConstants.dataPlaneProbeAttempts,
    Duration retryDelay = AppConstants.dataPlaneProbeRetryDelay,
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
    // 上限 6 与 AppConstants.dataPlaneProbeAttempts 一致，是**安全边界**而非默认值：
    // 单轮最坏耗时 = 6 × 6 秒请求超时 + 5 × 1 秒间隔 ≈ 41 秒，必须留在
    // dataPlaneObservationTimeout（60 秒）之内。因此这里写死 6 而不是引用常量——
    // 引用常量会让「把常量调大」同时把安全边界一起放宽，失去拦截作用。
    final attempts = maxAttempts.clamp(1, 6).toInt();
    final endpointValues = settings.enableTun
        ? AppConstants.tunConnectivityTestUrls
        : AppConstants.systemProxyConnectivityTestUrls;
    final endpoints = endpointValues.map(Uri.parse).toList(growable: false);
    int? lastStatusCode;
    // 是否至少有一次拿到了 HTTP 响应。这决定失败的性质：完全无响应说明通道可疑，
    // 有响应只说明端点不配合。两者此前被同一句话描述，属于语义错误。
    var sawAnyResponse = false;
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
          sawAnyResponse = true;
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
          log(
            '外部网络验证 $attempt/$attempts 未通过：'
            'cause=${safeRuntimeErrorCode(error)}；'
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
      // Keep this short. The home surface renders it in a single-line slot it
      // shares with the public-IP readout, and the full detail is already in
      // the runtime log. One disclaimer is enough; the previous pair of
      // hedges ("仅供参考" + "不代表节点失效") diluted the actual signal.
      //
      // 只描述**实际发生的事**，不再用「可能是验证站点受限」这类对冲措辞：
      // 有响应就把状态码说出来（通道已建立，是端点不配合），
      // 全程无响应才说无响应（通道可疑）。真因在日志的 cause= 里。
      final String warning;
      if (sawAnyResponse && lastStatusCode != null) {
        warning = '外部网络验证未通过（端点 HTTP $lastStatusCode），仅供参考';
      } else {
        warning = '外部网络验证未通过（连接无响应），仅供参考';
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
          '公网 IP 查询暂未完成：cause=${safeRuntimeErrorCode(error)}；'
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
