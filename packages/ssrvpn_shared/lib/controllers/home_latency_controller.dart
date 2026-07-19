import '../models/proxy_node.dart';
import 'home_node_controller.dart';

class HomeLatencyController {
  HomeLatencyController({Map<String, int>? latencies})
      : latencies = latencies ?? <String, int>{};

  final Map<String, int> latencies;
  final Map<String, int> _pending = {};
  int _batchGeneration = 0;

  bool get hasPending => _pending.isNotEmpty;

  int beginBatch() {
    _pending.clear();
    return ++_batchGeneration;
  }

  bool isCurrentBatch(int generation) => generation == _batchGeneration;

  bool queueForBatch(int generation, String nodeName, int latency) {
    if (!isCurrentBatch(generation)) return false;
    _pending[nodeName] = latency;
    return true;
  }

  bool flushBatchTo(
    int generation,
    List<ProxyNode> nodes, {
    DateTime? testedAt,
  }) {
    if (!isCurrentBatch(generation)) return false;
    _flushTo(nodes, testedAt: testedAt);
    return true;
  }

  bool finishBatch(
    int generation,
    List<ProxyNode> nodes, {
    DateTime? testedAt,
  }) {
    if (!flushBatchTo(generation, nodes, testedAt: testedAt)) return false;
    _batchGeneration++;
    return true;
  }

  void cancelBatch(int generation) {
    if (!isCurrentBatch(generation)) return;
    _pending.clear();
    _batchGeneration++;
  }

  int? latencyFor(ProxyNode node) => latencies[node.name] ?? node.latency;

  bool canSelect(ProxyNode node) {
    return HomeNodeController.canSelectNode(node, latencies);
  }

  void clear() {
    latencies.clear();
    _pending.clear();
    _batchGeneration++;
  }

  void remove(String nodeName) {
    latencies.remove(nodeName);
    _pending.remove(nodeName);
  }

  void _flushTo(List<ProxyNode> nodes, {DateTime? testedAt}) {
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
