import 'package:ssrvpn_shared/controllers/home_node_controller.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:test/test.dart';

void main() {
  ProxyNode node(String name, {int? latency}) => ProxyNode(
        name: name,
        type: 'ss',
        server: '127.0.0.1',
        port: 1000,
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
  });
}
