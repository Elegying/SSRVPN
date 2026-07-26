part of 'clash_service_base.dart';

/// Advisory node/internet state that is deliberately separate from the
/// process, service and runtime-configuration lifecycle.
mixin _ClashDataPlaneSupport {
  bool _dataPlaneObservationInProgress = false;
  String? _connectivityWarning;

  bool get isRunning;
  AppSettings get settings;
  void log(String message);
  void notifyStatusChanged();
  String _localHttpProxyConfig();
  String userConnectivityProxyConfig();
  @protected
  Duration get dataPlaneObservationTimeout => const Duration(seconds: 30);

  String? get connectivityWarning => _connectivityWarning;

  @protected
  Future<void> observeDataPlaneHealth() async {}

  @protected
  void setConnectivityWarning(String? value) {
    if (_connectivityWarning == value) return;
    _connectivityWarning = value;
    notifyStatusChanged();
  }

  @protected
  void clearConnectivityWarningSilently() {
    _connectivityWarning = null;
  }

  @protected
  void scheduleDataPlaneObservation() {
    if (_dataPlaneObservationInProgress || !isRunning) return;
    _dataPlaneObservationInProgress = true;
    final observation = Future<void>.sync(observeDataPlaneHealth);
    // Future.timeout does not cancel its source. Keep the ownership flag until
    // the real probe settles so a timed-out probe cannot overlap later probes.
    unawaited(
      observation.then<void>(
        (_) => _dataPlaneObservationInProgress = false,
        onError: (Object _, StackTrace __) {
          _dataPlaneObservationInProgress = false;
        },
      ),
    );
    unawaited(
      observation
          .timeout(dataPlaneObservationTimeout)
          .catchError((Object error, StackTrace stack) {
        log('数据通道观察失败，不影响核心生命周期: $error');
        if (isRunning) {
          setConnectivityWarning('数据通道检查未能完成，请稍后重试或切换节点');
        }
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
    final send = request ??
        (Uri uri) => client!.get(uri).timeout(const Duration(seconds: 6));
    final attempts = maxAttempts.clamp(1, 5).toInt();
    final endpointValues = settings.enableTun
        ? AppConstants.tunConnectivityTestUrls
        : const [AppConstants.defaultLatencyTestUrl];
    final endpoints = endpointValues.map(Uri.parse).toList(growable: false);
    int? lastStatusCode;
    try {
      for (var attempt = 1; attempt <= attempts; attempt++) {
        if (shouldContinue?.call() == false) return null;
        try {
          // Rotate independent endpoints across retries so one blocked or
          // rate-limited service cannot define the entire data-plane state.
          final endpoint = endpoints[(attempt - 1) % endpoints.length];
          final response = await send(endpoint);
          if (shouldContinue?.call() == false) return null;
          if (response.statusCode == 204 || response.statusCode == 200) {
            return null;
          }
          lastStatusCode = response.statusCode;
        } catch (_) {
          lastStatusCode = null;
        }
        if (attempt < attempts && retryDelay > Duration.zero) {
          await Future<void>.delayed(retryDelay);
        }
      }
      if (shouldContinue?.call() == false) return null;
      if (lastStatusCode != null) {
        return '已连接，但连续 $attempts 次网络验证返回 HTTP '
            '$lastStatusCode，请尝试切换节点';
      }
      return '已连接，但连续 $attempts 次网络验证失败，请尝试切换节点或刷新订阅';
    } finally {
      client?.close();
    }
  }

  Future<PublicIpInfo> fetchCurrentPublicIpInfo() async {
    final client = IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (_) => _localHttpProxyConfig(),
    );
    try {
      return await PublicIpInfoService(client: client).fetch();
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
