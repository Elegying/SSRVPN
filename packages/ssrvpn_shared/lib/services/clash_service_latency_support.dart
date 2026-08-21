part of 'clash_service_base.dart';

/// Node-aware latency probes and bounded batch orchestration.
mixin _ClashLatencySupport {
  bool get isRunning;
  AppSettings get settings;
  http.Client? get apiClient;
  String _apiUrl(String path);
  Map<String, String> apiHeaders({bool json = false});
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });

  /// Low-level direct TCP probe. Node callers should use [testNodeLatency].
  Future<int> testLatency(
    String server,
    int port, {
    int timeoutMs = 5000,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        server,
        port,
        timeout: Duration(milliseconds: timeoutMs),
      );
      socket.destroy();
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  /// Tests a materialized node without treating a TCP handshake as proof for
  /// UDP/QUIC-only proxy protocols.
  Future<int> testNodeLatency(
    ProxyNode node, {
    int timeoutMs = 5000,
  }) async {
    if (isRunning) {
      final apiLatency = await _testMihomoNodeLatency(node.name, timeoutMs);
      return apiLatency ?? -1;
    }
    if (const {'hysteria', 'hysteria2', 'tuic'}
        .contains(node.type.trim().toLowerCase())) {
      return -1;
    }
    return testLatency(node.server, node.port, timeoutMs: timeoutMs);
  }

  Future<int?> _testMihomoNodeLatency(String nodeName, int timeoutMs) async {
    final client = apiClient;
    if (client == null) {
      log(
        '节点延迟 API 不可用: HTTP 客户端未初始化',
        level: RuntimeLogLevel.warning,
        event: 'latency_test',
      );
      return null;
    }
    try {
      final uri = Uri.parse(
        _apiUrl('/proxies/${Uri.encodeComponent(nodeName)}/delay'),
      ).replace(
        queryParameters: {
          'timeout': '$timeoutMs',
          'url': settings.latencyTestUrl,
        },
      );
      final response = await client
          .get(uri, headers: apiHeaders())
          .timeout(Duration(milliseconds: timeoutMs + 1000));
      if (response.statusCode != 200) {
        log(
          '节点延迟 API 请求失败: HTTP ${response.statusCode}',
          level: RuntimeLogLevel.warning,
          event: 'latency_test',
        );
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        log(
          '节点延迟 API 响应无效: 非对象结果',
          level: RuntimeLogLevel.warning,
          event: 'latency_test',
        );
        return null;
      }
      final delay = decoded['delay'];
      if (delay is! num) {
        log(
          '节点延迟 API 响应无效: 缺少 delay',
          level: RuntimeLogLevel.warning,
          event: 'latency_test',
        );
        return null;
      }
      return delay > 0 ? delay.toInt() : -1;
    } catch (error) {
      log(
        '节点延迟 API 请求异常: $error',
        level: RuntimeLogLevel.warning,
        event: 'latency_test',
      );
      return null;
    }
  }

  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
    bool Function()? shouldContinue,
  }) async {
    final random = Random();
    for (var i = 0; i < nodes.length; i += concurrency) {
      if (shouldContinue?.call() == false) return;
      final batch = nodes.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map(
          (node) => testNodeLatency(node, timeoutMs: timeoutMs),
        ),
      );
      for (var j = 0; j < batch.length; j++) {
        if (shouldContinue?.call() == false) return;
        final latency = PrivateNodeLatencyPolicy.displayLatencyForNode(
          batch[j].name,
          results[j],
          random: random,
        );
        onResult(batch[j].name, latency);
      }
    }
  }
}
