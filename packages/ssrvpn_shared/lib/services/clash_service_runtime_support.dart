part of 'clash_service_base.dart';

/// Atomic runtime files and collision-free ephemeral port selection.
mixin _ClashRuntimeSupport {
  void updateSettings(AppSettings settings);
  void log(String message);

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

    if (proxyPort != preferred.proxyPort ||
        socksPort != preferred.socksPort ||
        apiPort != preferred.apiPort) {
      log(
        '检测到端口占用，已为本次连接自动调整: '
        '代理 ${preferred.proxyPort}->$proxyPort, '
        'SOCKS ${preferred.socksPort}->$socksPort, '
        'API ${preferred.apiPort}->$apiPort',
      );
    } else {
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
      if (await _canBindPort(port)) return port;
    }

    while (true) {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      final port = socket.port;
      await socket.close();
      if (!reserved.contains(port)) return port;
    }
  }

  Future<bool> _canBindPort(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
