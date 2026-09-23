import 'dart:convert';
import '../services/clash_config_generator.dart';
import '../services/subscription_node_codec.dart';
import '../models/proxy_node.dart';
import '../utils/node_display_policy.dart';
import '../utils/proxy_node_usage_policy.dart';

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
}

class HomeNodeController {
  HomeNodeController({
    Iterable<ProxyNode> nodes = const [],
    this.lastRevision = -1,
  }) : nodes = runnableNodesFrom(nodes);

  List<ProxyNode> nodes;
  int lastRevision;

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
    nodes = runnableNodesFrom(allNodes);
    return HomeNodeSyncResult(
      changed: true,
      isFirstSync: isFirstSync,
      hasNodes: nodes.isNotEmpty,
    );
  }

  /// Includes chain dependencies; ignores only fields never sent to the core.
  /// This value can contain credentials and must never be logged.
  static String? connectionSignature(Iterable<ProxyNode> nodes, String? name) {
    if (name == null) return null;
    final byName = {for (final node in nodes) node.name: node};
    final visited = <String>{};
    final chain = <Map<String, dynamic>>[];
    var current = name;
    while (true) {
      if (!visited.add(current)) return null;
      final node = byName[current];
      if (node == null) return null;
      final config = <String, dynamic>{
        ...node.extra,
        'name': node.name,
        'type': node.type,
        'server': node.server,
        'port': node.port
      };
      for (final key in ClashConfigGenerator.internalProxyKeys) {
        config.remove(key);
      }
      chain.add(config);
      final dependency = config['dialer-proxy'];
      if (dependency == null || dependency == '' || dependency == 'DIRECT') {
        break;
      }
      if (dependency is! String) return null;
      current = dependency;
    }
    return jsonEncode(SubscriptionNodeCodec.canonicalJsonValue(chain));
  }

  static bool connectionUnchanged(
      Iterable<ProxyNode> previous, Iterable<ProxyNode> next, String? name) {
    final old = connectionSignature(previous, name);
    return old != null && old == connectionSignature(next, name);
  }

  static ProxyNode? resolveDefaultNodeFrom(
    Iterable<ProxyNode> nodes,
    String? rememberedNodeName,
  ) {
    final runnable = runnableNodesFrom(nodes);
    if (rememberedNodeName != null && rememberedNodeName.isNotEmpty) {
      for (final node in runnable) {
        // A user can deliberately preselect an offline/timed-out node. Keep
        // that intent for the next connection; latency only guides fallback.
        if (node.name == rememberedNodeName) return node;
      }
    }
    final selectable = runnable
        .where(
          (node) =>
              node.latency != null &&
              NodeDisplayPolicy.isSelectableLatency(node.latency),
        )
        .toList();
    if (selectable.isNotEmpty) return selectable.first;
    // Unknown/failed latency is guidance, not a hard gate. This also gives a
    // fresh UDP/QUIC-only subscription a deterministic default node.
    return runnable.isEmpty ? null : runnable.first;
  }

  static ProxyNode? resolveRuntimeSelectedNodeFrom(
    Iterable<ProxyNode> nodes,
    String? runtimeNodeName,
  ) {
    final name = runtimeNodeName?.trim();
    if (name == null || name.isEmpty) return null;
    for (final node in runnableNodesFrom(nodes)) {
      if (node.name == name) return node;
    }
    return null;
  }

  static List<ProxyNode> runnableNodesFrom(Iterable<ProxyNode> nodes) {
    return nodes
        .where(ProxyNodeUsagePolicy.isRunnableNode)
        .toList(growable: false);
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
    Map<String, int> _,
  ) {
    return ProxyNodeUsagePolicy.isRunnableNode(node);
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
