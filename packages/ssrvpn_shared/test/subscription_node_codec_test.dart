import 'package:test/test.dart';
import 'package:ssrvpn_shared/services/subscription_node_codec.dart';

void main() {
  group('SubscriptionNodeCodec', () {
    test('normalizes editable proxy input without mutating the source', () {
      final source = <String, dynamic>{
        'name': ' Node A ',
        'type': 'VMESS',
        'server': ' example.com ',
        'port': '443',
        'uuid': 'id-1',
        'tls': 'yes',
        'alterId': '0',
        'latency': 42,
      };

      final normalized = SubscriptionNodeCodec.normalizeProxyConfig(source);

      expect(normalized['name'], 'Node A');
      expect(normalized['type'], 'vmess');
      expect(normalized['server'], 'example.com');
      expect(normalized['port'], 443);
      expect(normalized['tls'], isTrue);
      expect(normalized['alterId'], 0);
      expect(normalized['cipher'], 'auto');
      expect(normalized, isNot(contains('latency')));
      expect(source['port'], '443');
    });

    test('rejects invalid protocol requirements and ports', () {
      expect(
        () => SubscriptionNodeCodec.normalizeProxyConfig({
          'name': 'Bad',
          'type': 'ss',
          'server': 'example.com',
          'port': 70000,
          'cipher': 'aes-128-gcm',
          'password': 'secret',
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.normalizeProxyConfig({
          'name': 'Bad',
          'type': 'tuic',
          'server': 'example.com',
          'port': 443,
        }),
        throwsFormatException,
      );
    });

    test('encodes proxies as safe JSON flow maps', () {
      final encoded = SubscriptionNodeCodec.encodeConfig({
        'proxies': [
          {'name': 'Node: A', 'type': 'ss', 'port': 443},
        ],
        'mixed-port': 7890,
      });

      expect(encoded, contains('proxies:\n  - {"name":"Node: A"'));
      expect(encoded, contains('mixed-port: 7890'));
    });
  });
}
