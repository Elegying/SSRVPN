part of 'clash_service_base.dart';

/// Atomic runtime files and collision-free ephemeral port selection.
mixin _ClashRuntimeSupport {
  static const int _maxEphemeralPortAttempts = 32;

  void updateSettings(AppSettings settings);
  void log(String message);
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
    final proxyPort = await findAvailablePort(preferred.proxyPort, reserved);
    reserved.add(proxyPort);
    final socksPort = await findAvailablePort(preferred.socksPort, reserved);
    reserved.add(socksPort);
    final apiPort = await findAvailablePort(preferred.apiPort, reserved);

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

  Future<int> findAvailablePort(int preferred, Set<int> reserved) async {
    final candidates = <int>[
      preferred,
      for (var offset = 1; offset <= 50; offset++)
        if (preferred + offset <= 65535) preferred + offset,
    ];
    for (final port in candidates) {
      if (reserved.contains(port)) continue;
      if (await canBindRuntimePort(port)) return port;
    }

    for (var attempt = 0; attempt < _maxEphemeralPortAttempts; attempt++) {
      final port = await allocateEphemeralPortCandidate();
      if (reserved.contains(port)) continue;
      if (await canBindRuntimePort(port)) return port;
    }
    throw StateError('无法分配同时可用于 IPv4/IPv6 的可用运行端口');
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
