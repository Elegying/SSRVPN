import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';

void main() {
  group('ProxyNode', () {
    test('fromJson parses all fields', () {
      final node = ProxyNode.fromJson({
        'name': 'Test Node',
        'type': 'trojan',
        'server': 'test.example.com',
        'port': 443,
        'group': 'VIP',
        'latency': 156,
        'isOnline': true,
        'extra': {'sni': 'sni.example.com'},
      });

      expect(node.name, 'Test Node');
      expect(node.type, 'trojan');
      expect(node.server, 'test.example.com');
      expect(node.port, 443);
      expect(node.group, 'VIP');
      expect(node.latency, 156);
      expect(node.isOnline, isTrue);
      expect(node.extra['sni'], 'sni.example.com');
    });

    test('fromJson handles missing optional fields', () {
      final node = ProxyNode.fromJson({
        'name': 'Minimal',
        'server': 'min.example.com',
        'port': 1080,
      });

      expect(node.type, 'ss'); // default
      expect(node.group, '默认');
      expect(node.latency, isNull);
      expect(node.isOnline, isTrue);
    });

    test('latencyLevel: <200ms = green (0)', () {
      final node = ProxyNode(
        name: 'fast', type: 'ss', server: 's', port: 1, latency: 150,
      );
      expect(node.latencyLevel, 0);
    });

    test('latencyLevel: 200-499ms = yellow (1)', () {
      final node = ProxyNode(
        name: 'mid', type: 'ss', server: 's', port: 1, latency: 350,
      );
      expect(node.latencyLevel, 1);
    });

    test('latencyLevel: >=500ms = red (2)', () {
      final node = ProxyNode(
        name: 'slow', type: 'ss', server: 's', port: 1, latency: 800,
      );
      expect(node.latencyLevel, 2);
    });

    test('latencyLevel: null = red (2)', () {
      final node = ProxyNode(
        name: 'unknown', type: 'ss', server: 's', port: 1,
      );
      expect(node.latencyLevel, 2);
    });

    test('latencyText formats correctly', () {
      expect(
        ProxyNode(name: 'a', type: 'ss', server: 's', port: 1, latency: 42)
            .latencyText,
        '42ms',
      );
      expect(
        ProxyNode(name: 'a', type: 'ss', server: 's', port: 1).latencyText,
        '超时',
      );
    });

    test('copyWith does not mutate original', () {
      final original = ProxyNode(
        name: 'original', type: 'ss', server: 'srv', port: 1,
        extra: {'key': 'value'},
      );
      final copy = original.copyWith(name: 'copy', latency: 100);

      expect(original.name, 'original');
      expect(original.latency, isNull);
      expect(copy.name, 'copy');
      expect(copy.latency, 100);
      expect(copy.server, 'srv');
      expect(copy.extra['key'], 'value');
    });
  });
}
