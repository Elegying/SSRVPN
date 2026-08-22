part of 'clash_service_base.dart';

enum LocalMixedProxyReadiness {
  ready,
  configMismatch,
  listenerUnavailable,
}

String _safeRuntimeLogErrorCode(Object error) {
  try {
    return AppFailure.fromMessage(error).code.wireName;
  } catch (_) {
    return AppErrorCode.unknown.wireName;
  }
}

/// Atomic runtime files and collision-free ephemeral port selection.
mixin _ClashRuntimeSupport {
  static const int _maxEphemeralPortAttempts = 32;
  static const Duration _localMixedProxyProbeTimeout = Duration(seconds: 1);

  void updateSettings(AppSettings settings);
  AppSettings get settings;
  @protected
  String get runtimeApiSecret =>
      RuntimeConfigNamePolicy.canonicalApiSecret(settings.apiSecret);
  Future<Map<String, dynamic>?> getConfigs();
  void setLastHealthCheckError(String? value);
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });
  void setRuntimePortAdjustmentMessage(String? message);

  Future<void> writeStringAtomically(
    File file,
    String content, {
    Future<void> Function(File temp)? beforeWrite,
  }) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.create(exclusive: true);
      await beforeWrite?.call(temp);
      await temp.writeAsString(content, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> writeBytesAtomically(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  /// Resolves transient port conflicts without changing saved preferences.
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    final reserved = <int>{};
    final proxyPort = await findAvailableTcpUdpPort(
      preferred.proxyPort,
      reserved,
    );
    reserved.add(proxyPort);
    final socksPort = await findAvailableTcpUdpPort(
      preferred.socksPort,
      reserved,
    );
    reserved.add(socksPort);
    final availableApiPort = await findAvailablePort(
      preferred.apiPort,
      reserved,
    );
    final apiPort = availableApiPort != preferred.apiPort &&
            !reserved.contains(preferred.apiPort) &&
            await canReuseOccupiedApiPort(preferred)
        ? preferred.apiPort
        : availableApiPort;

    final runtime = preferred.copyWith(
      proxyPort: proxyPort,
      socksPort: socksPort,
      apiPort: apiPort,
    );
    updateSettings(runtime);

    final adjustments = <String>[
      if (proxyPort != preferred.proxyPort)
        '代理 ${preferred.proxyPort}→$proxyPort',
      if (socksPort != preferred.socksPort)
        'SOCKS ${preferred.socksPort}→$socksPort',
      if (apiPort != preferred.apiPort) 'API ${preferred.apiPort}→$apiPort',
    ];
    if (adjustments.isNotEmpty) {
      final message = '端口被占用，已临时调整：${adjustments.join('，')}';
      setRuntimePortAdjustmentMessage(message);
      log(message);
    } else {
      setRuntimePortAdjustmentMessage(null);
      log('端口检查通过: $proxyPort / $socksPort / $apiPort');
    }
    return runtime;
  }

  Future<int> findAvailablePort(int preferred, Set<int> reserved) =>
      _findAvailablePort(
        preferred,
        reserved,
        canBind: canBindRuntimePort,
        failureMessage: '无法分配同时可用于 IPv4/IPv6 的可用运行端口',
      );

  Future<int> findAvailableTcpUdpPort(int preferred, Set<int> reserved) =>
      _findAvailablePort(
        preferred,
        reserved,
        canBind: canBindTcpUdpRuntimePort,
        failureMessage: '无法分配同时可用于 TCP/UDP 的本地代理端口',
      );

  Future<int> _findAvailablePort(
    int preferred,
    Set<int> reserved, {
    required Future<bool> Function(int port) canBind,
    required String failureMessage,
  }) async {
    final candidates = <int>[
      preferred,
      for (var offset = 1; offset <= 50; offset++)
        if (preferred + offset <= 65535) preferred + offset,
    ];
    for (final port in candidates) {
      if (reserved.contains(port)) continue;
      if (await canBind(port)) return port;
    }

    for (var attempt = 0; attempt < _maxEphemeralPortAttempts; attempt++) {
      final port = await allocateEphemeralPortCandidate();
      if (reserved.contains(port)) continue;
      if (await canBind(port)) return port;
    }
    throw StateError(failureMessage);
  }

  /// Allocates a candidate only; [findAvailablePort] still rechecks both
  /// loopback stacks after releasing this temporary IPv4 reservation.
  @protected
  Future<int> allocateEphemeralPortCandidate() async {
    final socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final port = socket.port;
    await socket.close();
    return port;
  }

  @protected
  Future<bool> canBindRuntimePort(int port) async {
    ServerSocket? ipv4;
    ServerSocket? ipv6;
    try {
      ipv4 = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      try {
        ipv6 = await ServerSocket.bind(
          InternetAddress.loopbackIPv6,
          port,
          shared: false,
          v6Only: true,
        );
      } on SocketException catch (error) {
        if (!_isIpv6Unavailable(error)) return false;
      }
      return true;
    } on SocketException {
      return false;
    } finally {
      await ipv6?.close();
      await ipv4?.close();
    }
  }

  @protected
  Future<bool> canBindTcpUdpRuntimePort(int port) async {
    RawDatagramSocket? ipv4;
    RawDatagramSocket? ipv6;
    try {
      ipv4 = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        reuseAddress: false,
        reusePort: false,
      );
      try {
        ipv6 = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv6,
          port,
          reuseAddress: false,
          reusePort: false,
        );
      } on SocketException catch (error) {
        if (!_isIpv6Unavailable(error)) return false;
      }
      return await canBindRuntimePort(port);
    } on SocketException {
      return false;
    } finally {
      ipv6?.close();
      ipv4?.close();
    }
  }

  /// Verifies the local endpoint used by desktop system-proxy mode without
  /// depending on an external website. A transient `/configs` read failure is
  /// tolerated when the local SOCKS5 listener itself is ready; an explicit
  /// runtime-port mismatch is not.
  Future<LocalMixedProxyReadiness> checkLocalMixedProxyReadiness({
    Duration timeout = _localMixedProxyProbeTimeout,
  }) async {
    Map<String, dynamic>? configs;
    try {
      configs = await getConfigs();
    } catch (_) {
      configs = null;
    }
    if (configs != null && configs['mixed-port'] != settings.proxyPort) {
      return LocalMixedProxyReadiness.configMismatch;
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        settings.proxyPort,
        timeout: timeout,
      );
      socket.add(const [0x05, 0x01, 0x00]);
      await socket.flush();
      final response = await socket
          .expand<int>((chunk) => chunk)
          .take(2)
          .toList()
          .timeout(timeout);
      if (response.length == 2 && response[0] == 0x05 && response[1] == 0x00) {
        return LocalMixedProxyReadiness.ready;
      }
    } on Object {
      // The stable enum is enough for callers and avoids leaking socket data.
    } finally {
      socket?.destroy();
    }
    return LocalMixedProxyReadiness.listenerUnavailable;
  }

  String? localMixedProxyReadinessFailureMessage(
    LocalMixedProxyReadiness readiness,
  ) {
    return switch (readiness) {
      LocalMixedProxyReadiness.ready => null,
      LocalMixedProxyReadiness.configMismatch =>
        'LOCAL_PROXY_CONFIG_MISMATCH: Mihomo API 已就绪，但 mixed-port '
            '与本地代理端口 ${settings.proxyPort} 不一致',
      LocalMixedProxyReadiness.listenerUnavailable =>
        'LOCAL_PROXY_LISTENER_UNAVAILABLE: Mihomo API 已就绪，但本地代理端口 '
            '${settings.proxyPort} 未响应 SOCKS5 握手；可能被其他程序占用',
    };
  }

  Future<bool> verifyLocalMixedProxyReadiness() async {
    final readiness = await checkLocalMixedProxyReadiness();
    final error = localMixedProxyReadinessFailureMessage(readiness);
    if (error == null) return true;
    setLastHealthCheckError(error);
    return false;
  }

  /// Lets an embedded platform reuse its own authenticated idle controller.
  /// Other platforms keep the collision-safe default.
  @protected
  Future<bool> canReuseOccupiedApiPort(AppSettings preferred) async => false;

  bool _isIpv6Unavailable(SocketException error) {
    final code = error.osError?.errorCode;
    return code == 47 ||
        code == 49 ||
        code == 97 ||
        code == 99 ||
        code == 10047 ||
        code == 10049;
  }
}
