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
      expect(empty.shouldAutoTest, isFalse);

      final imported = controller.syncSubscriptionSnapshot(
        revision: 1,
        allNodes: [node('A'), node('B')],
      );
      expect(imported.changed, isTrue);
      expect(imported.isFirstSync, isFalse);
      expect(imported.hasNodes, isTrue);
      expect(imported.shouldPromptForImport, isFalse);
      expect(imported.shouldAutoTest, isTrue);
      expect(controller.nodes.map((node) => node.name), ['A', 'B']);
    });

    test('resolves remembered selectable node and skips timed-out nodes', () {
      final controller = HomeNodeController(nodes: [
        node('A', latency: 65535),
        node('B', latency: 30),
      ]);

      expect(controller.resolveDefaultNode('A')?.name, 'B');
      expect(controller.resolveDefaultNode('B')?.name, 'B');
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

      expect(controller.resolveDefaultNode('套餐到期：长期有效')?.name, 'Real Node');
      expect(controller.nodes.map((node) => node.name), ['Real Node']);
      expect(HomeNodeController.canSelectNode(nodes.first, const {}), isFalse);
      expect(controller.canSelect(controller.nodes.single), isTrue);
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
      final controller = HomeNodeController(nodes: [
        node('A'),
        node('B'),
        node('C'),
        node('D'),
      ]);

      controller.applyLatencies({'B': 65535, 'D': -1, 'A': 25, 'C': 80});
      controller.sortTimeoutLast();

      expect(controller.nodes.map((node) => node.name), ['A', 'C', 'B', 'D']);
      expect(controller.canSelect(controller.nodes[0]), isTrue);
      expect(controller.canSelect(controller.nodes[2]), isFalse);
    });

    test('builds collapsed subscription sections and keeps single nodes first',
        () {
      final sections = HomeNodeController.buildDisplaySections([
        node('Sub A 1', group: 'Feed A'),
        node('Single', group: '单独节点'),
        node('Sub B 1', group: 'Feed B'),
        node('Sub A 2', group: 'Feed A'),
      ]);

      expect(sections, hasLength(3));
      expect(sections[0].title, isNull);
      expect(sections[0].nodes.map((node) => node.name), ['Single']);
      expect(sections[1].title, 'Feed A');
      expect(sections[1].collapsible, isTrue);
      expect(sections[1].nodes.map((node) => node.name), [
        'Sub A 1',
        'Sub A 2',
      ]);
      expect(sections[2].title, 'Feed B');
    });

    test('keeps a single subscription flat', () {
      final sections = HomeNodeController.buildDisplaySections([
        node('Single', group: '单独节点'),
        node('Sub A 1', group: 'Feed A'),
        node('Sub A 2', group: 'Feed A'),
      ]);

      expect(sections, hasLength(2));
      expect(sections[0].nodes.map((node) => node.name), ['Single']);
      expect(sections[1].title, isNull);
      expect(sections[1].collapsible, isFalse);
      expect(sections[1].nodes.map((node) => node.name), [
        'Sub A 1',
        'Sub A 2',
      ]);
    });

    test('builds display rows from expanded subscription groups', () {
      final nodes = [
        node('Single', group: '单独节点'),
        node('Sub A 1', group: 'Feed A'),
        node('Sub B 1', group: 'Feed B'),
        node('Sub A 2', group: 'Feed A'),
      ];

      final collapsed = HomeNodeController.buildDisplayRows(nodes, {});
      expect(collapsed.map((row) => row.section?.title ?? row.node?.name), [
        'Single',
        'Feed A',
        'Feed B',
      ]);

      final expanded = HomeNodeController.buildDisplayRows(nodes, {'Feed A'});
      expect(expanded.map((row) => row.section?.title ?? row.node?.name), [
        'Single',
        'Feed A',
        'Sub A 1',
        'Sub A 2',
        'Feed B',
      ]);
    });
  });
}
