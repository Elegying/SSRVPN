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
      final batch = controller.beginBatch();

      expect(controller.queueForBatch(batch, 'B', 88), isTrue);
      expect(controller.hasPending, isTrue);

      expect(controller.flushBatchTo(batch, nodes, testedAt: testedAt), isTrue);

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

    test('a newer batch rejects callbacks and completion from an older batch',
        () {
      final nodes = [
        ProxyNode(name: 'A', type: 'ss', server: 'new.example.com', port: 443),
      ];
      final controller = HomeLatencyController();
      final older = controller.beginBatch();
      final newer = controller.beginBatch();

      expect(controller.queueForBatch(older, 'A', 65535), isFalse);
      expect(controller.flushBatchTo(older, nodes), isFalse);
      expect(controller.queueForBatch(newer, 'A', 42), isTrue);
      expect(controller.finishBatch(newer, nodes), isTrue);
      expect(nodes.single.latency, 42);
    });

    test('a current batch can flush progress before final completion', () {
      final nodes = [
        ProxyNode(name: 'A', type: 'ss', server: 'a.example.com', port: 443),
      ];
      final controller = HomeLatencyController();
      final batch = controller.beginBatch();

      expect(controller.queueForBatch(batch, 'A', 60), isTrue);
      expect(controller.flushBatchTo(batch, nodes), isTrue);
      expect(controller.isCurrentBatch(batch), isTrue);
      expect(nodes.single.latency, 60);

      expect(controller.queueForBatch(batch, 'A', 40), isTrue);
      expect(controller.finishBatch(batch, nodes), isTrue);
      expect(controller.isCurrentBatch(batch), isFalse);
      expect(nodes.single.latency, 40);
    });

    test('cancelling a batch invalidates pending results', () {
      final node =
          ProxyNode(name: 'A', type: 'ss', server: 'a.example.com', port: 443);
      final controller = HomeLatencyController();
      final batch = controller.beginBatch();
      controller.queueForBatch(batch, 'A', 50);

      controller.cancelBatch(batch);

      expect(controller.isCurrentBatch(batch), isFalse);
      expect(controller.flushBatchTo(batch, [node]), isFalse);
      expect(controller.finishBatch(batch, [node]), isFalse);
      expect(node.latency, isNull);
    });
  });
}
