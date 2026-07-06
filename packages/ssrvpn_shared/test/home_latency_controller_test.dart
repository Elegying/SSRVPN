import 'package:ssrvpn_shared/controllers/home_latency_controller.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:test/test.dart';

void main() {
  group('HomeLatencyController', () {
    test('queues and flushes latency updates into nodes', () {
      final nodes = [
        ProxyNode(name: 'A', type: 'ss', server: 'a.example.com', port: 443),
        ProxyNode(name: 'B', type: 'ss', server: 'b.example.com', port: 443),
      ];
      final controller = HomeLatencyController();
      final testedAt = DateTime(2026, 1, 1);

      controller.queue('B', 88);
      expect(controller.hasPending, isTrue);

      controller.flushTo(nodes, testedAt: testedAt);

      expect(controller.hasPending, isFalse);
      expect(controller.latencyFor(nodes[1]), 88);
      expect(nodes[1].latency, 88);
      expect(nodes[1].lastLatencyTest, testedAt);
    });

    test('sorts timed-out nodes after selectable nodes', () {
      final nodes = [
        ProxyNode(
            name: 'timeout', type: 'ss', server: 'a.example.com', port: 1),
        ProxyNode(name: 'fast', type: 'ss', server: 'b.example.com', port: 2),
      ];
      final controller = HomeLatencyController();

      controller.applyNow(nodes, 'timeout', 65535);
      controller.applyNow(nodes, 'fast', 24);

      expect(controller.timeoutLast(nodes).map((node) => node.name), [
        'fast',
        'timeout',
      ]);
    });

    test('canSelect reflects current latency state', () {
      final node = ProxyNode(
        name: 'A',
        type: 'ss',
        server: 'a.example.com',
        port: 443,
      );
      final controller = HomeLatencyController();

      expect(controller.canSelect(node), isTrue);
      controller.applyNow([node], 'A', 65535);
      expect(controller.canSelect(node), isFalse);
    });
  });
}
