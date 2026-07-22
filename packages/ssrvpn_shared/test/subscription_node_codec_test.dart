import 'package:test/test.dart';
import 'package:ssrvpn_shared/services/subscription_node_codec.dart';
import 'package:yaml/yaml.dart';

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

    test(
      'preserves valid whitespace in ordinary fields through YAML encoding',
      () {
        const password = 'pass\tword\nnext\rreturn';
        const authentication = 'auth\tvalue\nnext\rreturn';
        const nestedHeader = 'Bearer\ttoken\nnext\rreturn';
        final normalized = SubscriptionNodeCodec.normalizeProxyConfig({
          'name': ' \u0000White\u0001\tspace\n\r Node\u001f\u007f ',
          'type': 'ss',
          'server': 'example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': 'pass\u0000\u0001\tword\nnext\rreturn\u007f',
          'auth-str': authentication,
          'ws-opts': {
            'headers': {'Authorization': nestedHeader},
          },
        });

        expect(normalized['name'], 'Whitespace Node');
        expect(normalized['password'], password);
        expect(normalized['auth-str'], authentication);
        expect(
          ((normalized['ws-opts'] as Map)['headers'] as Map)['Authorization'],
          nestedHeader,
        );

        final encoded = SubscriptionNodeCodec.encodeConfig({
          'proxies': [normalized],
        });
        final parsed = loadYaml(encoded) as YamlMap;
        final proxy = (parsed['proxies'] as YamlList).single as YamlMap;
        final wsOptions = proxy['ws-opts'] as YamlMap;
        final headers = wsOptions['headers'] as YamlMap;

        expect(proxy['name'], 'Whitespace Node');
        expect(proxy['password'], password);
        expect(proxy['auth-str'], authentication);
        expect(headers['Authorization'], nestedHeader);
      },
    );

    test(
      'preserves whitespace-only credentials and sanitizes direct encoding',
      () {
        const whitespace = '\t\n\r';
        final normalized = SubscriptionNodeCodec.normalizeProxyConfig({
          'name': 'Whitespace Credential',
          'type': 'ss',
          'server': 'example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': whitespace,
          'auth-str': whitespace,
          'nested': {'header': whitespace},
        });

        expect(normalized['password'], whitespace);
        expect(normalized['auth-str'], whitespace);
        expect((normalized['nested'] as Map)['header'], whitespace);

        final encoded = SubscriptionNodeCodec.encodeConfig({
          'proxies': [
            {
              'name': 'N\tod\ne\r',
              'type': 'ss',
              'server': 'example.com',
              'port': 443,
              'cipher': 'aes-256-gcm',
              'password': '\u0000\t\n\r\u0001\u007f',
              'nested': {'hea\u0000der': whitespace},
            },
          ],
          'proxy-groups': [
            {
              'name': 'G\tro\nup\r',
              'type': 'select',
              'proxies': ['N\tod\ne\r'],
            },
          ],
        });
        final parsed = loadYaml(encoded) as YamlMap;
        final proxy = (parsed['proxies'] as YamlList).single as YamlMap;
        final group = (parsed['proxy-groups'] as YamlList).single as YamlMap;

        expect(proxy['name'], 'Node');
        expect(proxy['password'], whitespace);
        expect((proxy['nested'] as YamlMap).keys, ['header']);
        expect((proxy['nested'] as YamlMap)['header'], whitespace);
        expect(group['name'], 'Group');
        expect((group['proxies'] as YamlList).cast<String>(), ['Node']);
      },
    );

    test('rejects map key collisions after data-scalar sanitization', () {
      expect(
        () => SubscriptionNodeCodec.jsonValue({
          'pass\u0000word': 'hidden',
          'password': 'visible',
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.normalizeProxyConfig({
          'name': 'Collision',
          'type': 'ss',
          'server': 'example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': 'visible',
          'pass\u0000word': 'hidden',
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.normalizeProxyConfig({
          'name': 'Collision',
          'type': 'ss',
          'server': 'example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'pass\u0000word': '\u0000',
          'password': 'visible',
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.encodeConfig({
          'mixed\u0000-port': 7890,
          'mixed-port': 7891,
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.encodeConfig({
          'metadata': {
            'hea\u0000der': 'hidden',
            'header': 'visible',
          },
        }),
        throwsFormatException,
      );
    });

    test('does not trim ordinary map keys while sanitizing them', () {
      final parsed = loadYaml(
        SubscriptionNodeCodec.encodeConfig({
          ' header ': 'spaced',
          'header': 'plain',
        }),
      ) as YamlMap;

      expect(parsed[' header '], 'spaced');
      expect(parsed['header'], 'plain');
    });

    test('preserves standard source group names for subscription storage', () {
      final parsed = loadYaml(
        SubscriptionNodeCodec.encodeConfig({
          'proxies': [
            {'name': 'Node'},
          ],
          'proxy-groups': [
            {
              'name': 'PROXY',
              'type': 'select',
              'proxies': ['Node'],
            },
          ],
        }),
      ) as YamlMap;
      final group = (parsed['proxy-groups'] as YamlList).single as YamlMap;

      expect(group['name'], 'PROXY');
      expect((group['proxies'] as YamlList).cast<String>(), ['Node']);
    });

    test('rejects proxy and group namespace collisions after canonicalizing',
        () {
      expect(
        () => SubscriptionNodeCodec.encodeConfig({
          'proxies': [
            {'name': 'Node'},
            {'name': 'N\u0000ode'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.encodeConfig({
          'proxies': [
            {'name': 'Shared'},
          ],
          'proxy-groups': [
            {
              'name': 'Shared',
              'type': 'select',
              'proxies': ['Shared'],
            },
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.encodeConfig({
          'proxies': [
            {'name': 'D\u0000IRECT'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => SubscriptionNodeCodec.encodeConfig({
          'proxy-groups': [
            {
              'name': 'Group',
              'type': 'select',
              'proxies': ['N\u0000ode', 'Node'],
            },
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
