part of 'clash_service_base.dart';

/// Node-aware latency probes and bounded batch orchestration.
mixin _ClashLatencySupport {
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });

  /// Low-level direct TCP probe.
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

  /// Tests every node with the same direct TCP socket probe.
  Future<int> testNodeLatency(
    ProxyNode node, {
    int timeoutMs = 5000,
  }) =>
      testLatency(node.server, node.port, timeoutMs: timeoutMs);

  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
    bool Function()? shouldContinue,
  }) async {
    final random = Random();
    final failures = <String, int>{};
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
        if (results[j] <= 0 ||
            results[j] >= NodeDisplayPolicy.timeoutLatencyMs) {
          final reason = NodeDisplayPolicy.failureExplanation(results[j]);
          failures.update(reason, (count) => count + 1, ifAbsent: () => 1);
        }
        final latency = PrivateNodeLatencyPolicy.displayLatencyForNode(
          batch[j].name,
          results[j],
          random: random,
        );
        onResult(batch[j].name, latency);
      }
    }
    if (shouldContinue?.call() == false) return;
    for (final failure in failures.entries) {
      log('${failure.value} 个节点：${failure.key}',
          level: RuntimeLogLevel.warning, event: 'latency_result');
    }
  }
}
