import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/utils/proxy_node_usage_policy.dart';
import 'package:test/test.dart';

void main() {
  group('ProxyNodeUsagePolicy', () {
    test('accepts only the proxy types supported by the project', () {
      final supported = <Map<String, dynamic>>[
        _proxy('ss', {'cipher': 'aes-256-gcm', 'password': 'secret'}),
        _proxy('ssr', {
          'cipher': 'aes-256-cfb',
          'password': 'secret',
          'protocol': 'origin',
          'obfs': 'plain',
        }),
        _proxy('vmess', {'uuid': 'uuid'}),
        _proxy('vless', {'uuid': 'uuid'}),
        _proxy('trojan', {'password': 'secret'}),
        _proxy('anytls', {'password': 'secret'}),
        _proxy('hysteria', {'auth-str': 'secret'}),
        _proxy('hysteria2', {'password': 'secret'}),
        _proxy('tuic', {'token': 'secret'}),
        _proxy('snell', {'psk': 'secret'}),
        _proxy('socks'),
        _proxy('socks5'),
        _proxy('http'),
      ];

      expect(
        supported.map(ProxyNodeUsagePolicy.isRunnableProxyMap),
        everyElement(isTrue),
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(_proxy('unsupported')),
        isFalse,
      );
    });

    test('requires every protocol-specific field', () {
      final requiredFields = <String, Map<String, dynamic>>{
        'ss': {'cipher': 'aes-256-gcm', 'password': 'secret'},
        'ssr': {
          'cipher': 'aes-256-cfb',
          'password': 'secret',
          'protocol': 'origin',
          'obfs': 'plain',
        },
        'vmess': {'uuid': 'uuid'},
        'vless': {'uuid': 'uuid'},
        'trojan': {'password': 'secret'},
        'anytls': {'password': 'secret'},
        'hysteria': {'auth-str': 'secret'},
        'hysteria2': {'password': 'secret'},
        'tuic': {'uuid': 'uuid', 'password': 'secret'},
        'snell': {'psk': 'secret'},
      };

      for (final entry in requiredFields.entries) {
        for (final requiredKey in entry.value.keys) {
          final missing = Map<String, dynamic>.from(entry.value)
            ..remove(requiredKey);
          expect(
            ProxyNodeUsagePolicy.isRunnableProxyMap(
              _proxy(entry.key, missing),
            ),
            isFalse,
            reason: '${entry.key} must require $requiredKey',
          );
        }
      }

      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('hysteria', {'auth': 'secret'}),
        ),
        isTrue,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('tuic', {'token': 'secret'}),
        ),
        isTrue,
      );
    });

    test('requires valid ports and non-empty base fields', () {
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('ss', {'cipher': 'aes-256-gcm', 'password': 'secret'})
            ..['port'] = 0,
        ),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('ss', {'cipher': 'aes-256-gcm', 'password': 'secret'})
            ..['port'] = 65536,
        ),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({
          ..._proxy('ss'),
          'server': '',
        }),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({..._proxy('ss'), 'name': ''}),
        isFalse,
      );
    });

    test('bounds untrusted scalar fields conservatively', () {
      final valid = _proxy('trojan', {'password': 'secret'});

      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({
          ...valid,
          'name': 'n' * 513,
        }),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({
          ...valid,
          'server': 's' * 1025,
        }),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({
          ...valid,
          'name': '${' ' * 513}n',
        }),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('trojan', {'password': 'p' * 8192}),
        ),
        isTrue,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('trojan', {'password': 'p' * 8193}),
        ),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('trojan', {'password': '   '}),
        ),
        isFalse,
      );
      expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap(
          _proxy('trojan', {
            'password': ['not', 'a', 'scalar'],
          }),
        ),
        isFalse,
      );
    });

    test('filters bad YAML nodes without discarding valid siblings', () {
      final parsed = SubscriptionParser.parseYaml('''
proxies:
  - name: Valid
    type: trojan
    server: valid.example.com
    port: 443
    password: secret
  - name: Too High
    type: trojan
    server: high.example.com
    port: 65536
    password: secret
  - name: Unknown
    type: unsupported
    server: unknown.example.com
    port: 443
  - name: Missing Server
    type: trojan
    port: 443
  - name: Missing Password
    type: trojan
    server: missing.example.com
    port: 443
''');

      expect(parsed.nodes.map((node) => node.name), ['Valid']);
    });

    test('applies the same checks to materialized nodes', () {
      final valid = ProxyNode.fromJson(
        _proxy('trojan', {'password': 'secret'}),
      );
      final invalid = ProxyNode.fromJson(
        _proxy('trojan', {'password': 'secret'})..['port'] = 70000,
      );

      expect(ProxyNodeUsagePolicy.isRunnableNode(valid), isTrue);
      expect(ProxyNodeUsagePolicy.isRunnableNode(invalid), isFalse);
    });

    test('keeps base-only validation for already materialized nodes', () {
      final rawProxy = _proxy('ss');
      final materialized = ProxyNode.fromJson(rawProxy);

      expect(ProxyNodeUsagePolicy.isRunnableProxyMap(rawProxy), isFalse);
      expect(ProxyNodeUsagePolicy.isRunnableNode(materialized), isTrue);
    });
  });
}

Map<String, dynamic> _proxy(
  String type, [
  Map<String, dynamic> fields = const {},
]) {
  return {
    'name': 'Node',
    'type': type,
    'server': 'example.com',
    'port': 443,
    ...fields,
  };
}
