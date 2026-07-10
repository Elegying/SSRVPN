import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/utils/node_country_policy.dart';
import 'package:test/test.dart';

void main() {
  group('countryCodeForProxyNode', () {
    test('uses explicit country metadata first', () {
      final node = ProxyNode(
        name: 'Tokyo node',
        type: 'ss',
        server: 'example.com',
        port: 443,
        extra: {'countryCode': 'uk'},
      );

      expect(countryCodeForProxyNode(node), 'GB');
    });

    test('detects known regions from node name and server', () {
      final node = ProxyNode(
        name: 'VIP 新加坡 01',
        type: 'ss',
        server: 'sg.example.com',
        port: 443,
      );

      expect(countryCodeForProxyNode(node), 'SG');
    });

    test('falls back to unknown when no country hint exists', () {
      final node = ProxyNode(
        name: 'edge',
        type: 'ss',
        server: 'proxy.example.com',
        port: 443,
      );

      expect(countryCodeForProxyNode(node), 'UN');
    });
  });
}
