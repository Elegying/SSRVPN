import '../models/proxy_node.dart';
import '../utils/node_display_policy.dart';

class HomeNodeSyncResult {
  const HomeNodeSyncResult({
    required this.changed,
    required this.isFirstSync,
    required this.hasNodes,
  });

  final bool changed;
  final bool isFirstSync;
  final bool hasNodes;

  bool get shouldPromptForImport => changed && !hasNodes;
  bool get shouldAutoTest => changed && hasNodes;
}

class HomeNodeController {
  HomeNodeController({
    Iterable<ProxyNode> nodes = const [],
    Map<String, int>? latencies,
    this.lastRevision = -1,
    this.selectedNode,
  })  : nodes = List<ProxyNode>.from(nodes),
        latencies = latencies ?? <String, int>{};

  List<ProxyNode> nodes;
  final Map<String, int> latencies;
  int lastRevision;
  ProxyNode? selectedNode;

  HomeNodeSyncResult syncSubscriptionSnapshot({
    required int revision,
    required Iterable<ProxyNode> allNodes,
  }) {
    if (revision == lastRevision) {
      return HomeNodeSyncResult(
        changed: false,
        isFirstSync: false,
        hasNodes: nodes.isNotEmpty,
      );
    }

    final isFirstSync = lastRevision == -1;
    lastRevision = revision;
    nodes = List<ProxyNode>.from(allNodes);
    return HomeNodeSyncResult(
      changed: true,
      isFirstSync: isFirstSync,
      hasNodes: nodes.isNotEmpty,
    );
  }

  ProxyNode? resolveDefaultNode(String? rememberedNodeName) {
    return resolveDefaultNodeFrom(nodes, rememberedNodeName);
  }

  bool canSelect(ProxyNode node) {
    return canSelectNode(node, latencies);
  }

  void applyLatencies(Map<String, int> batch, {DateTime? testedAt}) {
    applyLatenciesTo(nodes, latencies, batch, testedAt: testedAt);
  }

  void sortTimeoutLast() {
    nodes = timeoutLast(nodes, latencies);
  }

  static ProxyNode? resolveDefaultNodeFrom(
    Iterable<ProxyNode> nodes,
    String? rememberedNodeName,
  ) {
    final selectable = nodes
        .where((node) => NodeDisplayPolicy.isSelectableLatency(node.latency))
        .toList();
    if (selectable.isEmpty) return null;
    if (rememberedNodeName != null && rememberedNodeName.isNotEmpty) {
      for (final node in selectable) {
        if (node.name == rememberedNodeName) return node;
      }
    }
    return selectable.first;
  }

  static void applyLatenciesTo(
    Iterable<ProxyNode> nodes,
    Map<String, int> latencies,
    Map<String, int> batch, {
    DateTime? testedAt,
  }) {
    if (batch.isEmpty) return;
    latencies.addAll(batch);
    final now = testedAt ?? DateTime.now();
    for (final node in nodes) {
      final latency = batch[node.name];
      if (latency == null) continue;
      node.latency = latency;
      node.lastLatencyTest = now;
    }
  }

  static bool canSelectNode(
    ProxyNode node,
    Map<String, int> latencies,
  ) {
    return NodeDisplayPolicy.isSelectableLatency(
      latencies[node.name] ?? node.latency,
    );
  }

  static List<ProxyNode> timeoutLast(
    Iterable<ProxyNode> nodes,
    Map<String, int> latencies,
  ) {
    return NodeDisplayPolicy.timeoutLast(
      nodes,
      latencyOf: (node) => latencies[node.name] ?? node.latency,
    );
  }
}
