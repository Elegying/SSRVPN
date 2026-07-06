import '../models/proxy_node.dart';
import 'home_node_controller.dart';

class HomeLatencyController {
  HomeLatencyController({Map<String, int>? latencies})
      : latencies = latencies ?? <String, int>{};

  final Map<String, int> latencies;
  final Map<String, int> _pending = {};

  bool get hasPending => _pending.isNotEmpty;

  int? latencyFor(ProxyNode node) => latencies[node.name] ?? node.latency;

  bool canSelect(ProxyNode node) {
    return HomeNodeController.canSelectNode(node, latencies);
  }

  void queue(String nodeName, int latency) {
    _pending[nodeName] = latency;
  }

  void clearPending() {
    _pending.clear();
  }

  void clear() {
    latencies.clear();
    _pending.clear();
  }

  void remove(String nodeName) {
    latencies.remove(nodeName);
    _pending.remove(nodeName);
  }

  void flushTo(List<ProxyNode> nodes, {DateTime? testedAt}) {
    if (_pending.isEmpty) return;
    final batch = Map<String, int>.from(_pending);
    _pending.clear();
    HomeNodeController.applyLatenciesTo(nodes, latencies, batch,
        testedAt: testedAt);
  }

  void applyNow(
    List<ProxyNode> nodes,
    String nodeName,
    int latency, {
    DateTime? testedAt,
  }) {
    HomeNodeController.applyLatenciesTo(
      nodes,
      latencies,
      {nodeName: latency},
      testedAt: testedAt,
    );
  }

  List<ProxyNode> timeoutLast(Iterable<ProxyNode> nodes) {
    return HomeNodeController.timeoutLast(nodes, latencies);
  }
}
