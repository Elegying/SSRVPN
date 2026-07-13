import '../models/proxy_node.dart';
import '../services/subscription_parser.dart';
import '../utils/node_display_policy.dart';
import '../utils/proxy_node_usage_policy.dart';

class HomeNodeSection {
  const HomeNodeSection({
    required this.title,
    required this.nodes,
    required this.collapsible,
  });

  final String? title;
  final List<ProxyNode> nodes;
  final bool collapsible;
}

class HomeNodeDisplayRow {
  const HomeNodeDisplayRow.section(this.section) : node = null;
  const HomeNodeDisplayRow.node(this.node) : section = null;

  final HomeNodeSection? section;
  final ProxyNode? node;

  bool get isSection => section != null;
}

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
  })  : nodes = runnableNodesFrom(nodes),
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
    nodes = runnableNodesFrom(allNodes);
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
    final selectable = runnableNodesFrom(nodes)
        .where(
          (node) => NodeDisplayPolicy.isSelectableLatency(node.latency),
        )
        .toList();
    if (selectable.isEmpty) return null;
    if (rememberedNodeName != null && rememberedNodeName.isNotEmpty) {
      for (final node in selectable) {
        if (node.name == rememberedNodeName) return node;
      }
    }
    return selectable.first;
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
    Map<String, int> latencies,
  ) {
    return NodeDisplayPolicy.isSelectableLatency(
          latencies[node.name] ?? node.latency,
        ) &&
        ProxyNodeUsagePolicy.isRunnableNode(node);
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

  static List<HomeNodeSection> buildDisplaySections(
    Iterable<ProxyNode> nodes,
  ) {
    final standalone = <ProxyNode>[];
    final regular = <ProxyNode>[];
    final groups = <String, List<ProxyNode>>{};

    for (final node in nodes) {
      if (!ProxyNodeUsagePolicy.isRunnableNode(node)) continue;
      final group = node.group.trim();
      if (group == SubscriptionParser.standaloneGroupName) {
        standalone.add(node);
        continue;
      }
      regular.add(node);
      if (_isSubscriptionGroup(group)) {
        groups.putIfAbsent(group, () => <ProxyNode>[]).add(node);
      }
    }

    final sections = <HomeNodeSection>[];
    if (standalone.isNotEmpty) {
      sections.add(
        HomeNodeSection(
          title: null,
          nodes: standalone,
          collapsible: false,
        ),
      );
    }

    if (groups.length < 2) {
      if (regular.isNotEmpty) {
        sections.add(
          HomeNodeSection(title: null, nodes: regular, collapsible: false),
        );
      }
      return sections;
    }

    for (final entry in groups.entries) {
      sections.add(
        HomeNodeSection(
          title: entry.key,
          nodes: entry.value,
          collapsible: true,
        ),
      );
    }

    final groupedNodes = groups.values.expand((nodes) => nodes).toSet();
    final ungrouped = regular
        .where((node) => !groupedNodes.contains(node))
        .toList(growable: false);
    if (ungrouped.isNotEmpty) {
      sections.add(
        HomeNodeSection(title: null, nodes: ungrouped, collapsible: false),
      );
    }
    return sections;
  }

  static List<HomeNodeDisplayRow> buildDisplayRows(
    Iterable<ProxyNode> nodes,
    Set<String> expandedGroups,
  ) {
    final rows = <HomeNodeDisplayRow>[];
    for (final section in buildDisplaySections(nodes)) {
      if (!section.collapsible) {
        rows.addAll(section.nodes.map(HomeNodeDisplayRow.node));
        continue;
      }

      final title = section.title!;
      rows.add(HomeNodeDisplayRow.section(section));
      if (!expandedGroups.contains(title)) continue;
      rows.addAll(section.nodes.map(HomeNodeDisplayRow.node));
    }
    return rows;
  }

  static bool _isSubscriptionGroup(String group) {
    return group.isNotEmpty && group != '默认' && group != '全部节点';
  }
}
