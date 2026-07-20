import 'package:ssrvpn_shared/controllers/home_node_controller.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:test/test.dart';

void main() {
  ProxyNode node(
    String name, {
    String type = 'ss',
    String server = '127.0.0.1',
    int port = 1000,
    int? latency,
    String group = '默认',
  }) =>
      ProxyNode(
        name: name,
        type: type,
        server: server,
        port: port,
        group: group,
        latency: latency,
      );

  group('HomeNodeController', () {
    test('syncs empty first snapshot and imported nodes', () {
      final controller = HomeNodeController();

      final empty = controller.syncSubscriptionSnapshot(
        revision: 0,
        allNodes: const [],
      );
      expect(empty.changed, isTrue);
      expect(empty.isFirstSync, isTrue);
      expect(empty.hasNodes, isFalse);
      expect(empty.shouldPromptForImport, isTrue);

      final imported = controller.syncSubscriptionSnapshot(
        revision: 1,
        allNodes: [node('A'), node('B')],
      );
      expect(imported.changed, isTrue);
      expect(imported.isFirstSync, isFalse);
      expect(imported.hasNodes, isTrue);
      expect(imported.shouldPromptForImport, isFalse);
      expect(controller.nodes.map((node) => node.name), ['A', 'B']);
    });

    test('keeps a remembered runnable node even when its latency timed out',
        () {
      final controller = HomeNodeController(nodes: [
        node('A', latency: 65535),
        node('B', latency: 30),
      ]);

      expect(
        HomeNodeController.resolveDefaultNodeFrom(controller.nodes, 'A')?.name,
        'A',
      );
      expect(
        HomeNodeController.resolveDefaultNodeFrom(controller.nodes, 'B')?.name,
        'B',
      );
      expect(
        HomeNodeController.resolveDefaultNodeFrom(controller.nodes, null)?.name,
        'B',
      );
    });

    test('resolves runtime selected node from Mihomo state', () {
      final nodes = [
        node('A'),
        node('B'),
        node('套餐到期：长期有效'),
      ];

      expect(
        HomeNodeController.resolveRuntimeSelectedNodeFrom(nodes, ' B ')?.name,
        'B',
      );
      expect(
        HomeNodeController.resolveRuntimeSelectedNodeFrom(nodes, 'Missing'),
        isNull,
      );
      expect(
        HomeNodeController.resolveRuntimeSelectedNodeFrom(
          nodes,
          '套餐到期：长期有效',
        ),
        isNull,
      );
    });

    test('skips subscription info pseudo nodes for default selection', () {
      final nodes = [
        node('套餐到期：长期有效', latency: 30),
        node('剩余流量：993.95 GB', latency: 40),
        node('Real Node', latency: 50),
      ];
      final controller = HomeNodeController(nodes: nodes);

      expect(
        HomeNodeController.resolveDefaultNodeFrom(
          controller.nodes,
          '套餐到期：长期有效',
        )?.name,
        'Real Node',
      );
      expect(controller.nodes.map((node) => node.name), ['Real Node']);
      expect(HomeNodeController.canSelectNode(nodes.first, const {}), isFalse);
      expect(
        HomeNodeController.canSelectNode(controller.nodes.single, const {}),
        isTrue,
      );
    });

    test('returns only runnable nodes from subscription snapshots', () {
      final nodes = [
        node('套餐到期：长期有效'),
        node('Missing Server', server: ''),
        node('Missing Port', port: 0),
        node('Built In', type: 'builtin'),
        node('Real Node'),
      ];
      final controller = HomeNodeController();

      final sync = controller.syncSubscriptionSnapshot(
        revision: 1,
        allNodes: nodes,
      );

      expect(sync.hasNodes, isTrue);
      expect(
          HomeNodeController.runnableNodesFrom(nodes).map((node) => node.name),
          ['Real Node']);
      expect(controller.nodes.map((node) => node.name), ['Real Node']);
    });

    test('applies latency batch and moves only timed-out nodes to bottom', () {
      final nodes = [
        node('A'),
        node('B'),
        node('C'),
        node('D'),
      ];
      final latencies = <String, int>{};

      HomeNodeController.applyLatenciesTo(
        nodes,
        latencies,
        {'B': 65535, 'D': -1, 'A': 25, 'C': 80},
      );
      final sorted = HomeNodeController.timeoutLast(nodes, latencies);

      expect(sorted.map((node) => node.name), ['A', 'C', 'B', 'D']);
      expect(HomeNodeController.canSelectNode(sorted[0], latencies), isTrue);
      expect(HomeNodeController.canSelectNode(sorted[2], latencies), isFalse);
    });
  });
}
