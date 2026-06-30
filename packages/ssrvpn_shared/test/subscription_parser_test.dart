import 'dart:convert';
import 'package:test/test.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';

void main() {
  group('SubscriptionParser', () {
    group('isSsrLink', () {
      test('detects SSR links', () {
        expect(SubscriptionParser.isSsrLink('ssr://abc123'), isTrue);
        expect(SubscriptionParser.isSsrLink('SSR://abc123'), isTrue);
        expect(SubscriptionParser.isSsrLink('http://example.com'), isFalse);
        expect(SubscriptionParser.isSsrLink(''), isFalse);
      });
    });

    group('isLikelyBase64', () {
      test('detects Base64 strings', () {
        expect(
          SubscriptionParser.isLikelyBase64('SGVsbG8gV29ybGQhSGVsbG8gV29ybGQh'),
          isTrue,
        );
        expect(SubscriptionParser.isLikelyBase64('abc'), isFalse);
        expect(SubscriptionParser.isLikelyBase64('123'), isFalse);
      });
    });

    group('parseYaml', () {
      test('handles empty input', () {
        final result = SubscriptionParser.parseYaml('');
        expect(result.isEmpty, isTrue);
      });

      test('handles invalid YAML', () {
        final result = SubscriptionParser.parseYaml('invalid: yaml: content');
        expect(result, isNotNull);
      });

      test('parses proxies and groups', () {
        final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
proxy-groups:
  - name: "Auto"
    type: url-test
    proxies:
      - "Test Node"
''';
        final result = SubscriptionParser.parseYaml(yaml);
        expect(result.nodes, hasLength(1));
        expect(result.nodes.first.name, equals('Test Node'));
        expect(result.groups, hasLength(1));
        expect(result.groups.first.name, equals('Auto'));
      });

      test('parses string ports and skips unknown group entries', () {
        final yaml = '''
proxies:
  - name: "String Port"
    type: trojan
    server: example.com
    port: "8443"
    password: "secret"
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "String Port"
      - "Missing Node"
      - "DIRECT"
''';
        final result = SubscriptionParser.parseYaml(yaml);
        expect(result.nodes, hasLength(1));
        expect(result.nodes.first.port, equals(8443));
        expect(
          result.groups.first.nodes.map((node) => node.name),
          equals(['String Port', 'DIRECT']),
        );
      });
    });

    group('importSsrLink', () {
      test('parses valid SSR link', () {
        final server = 'example.com';
        final port = '443';
        final protocol = 'auth_aes128_md5';
        final method = 'aes-256-cfb';
        final obfs = 'tls1.2_ticket_auth';
        final password = 'testpassword';
        final passwordB64 =
            base64Url.encode(utf8.encode(password)).replaceAll('=', '');

        final mainPart = '$server:$port:$protocol:$method:$obfs:$passwordB64';
        final encoded =
            base64Url.encode(utf8.encode(mainPart)).replaceAll('=', '');
        final ssrLink = 'ssr://$encoded';

        final result = SubscriptionParser.importSsrLink(ssrLink);
        expect(result, isNotNull);
        expect(result, contains('proxies:'));
        expect(result, contains('server: "example.com"'));
        expect(result, contains('port: 443'));
      });

      test('rejects non-SSR links', () {
        expect(SubscriptionParser.importSsrLink('http://example.com'), isNull);
        expect(SubscriptionParser.importSsrLink(''), isNull);
      });
    });

    group('proxyFromUri', () {
      test('parses trojan link', () {
        final uri =
            'trojan://password123@example.com:443?sni=sni.example.com#MyTrojan';
        final proxy = SubscriptionParser.proxyFromUri(uri);
        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('trojan'));
        expect(proxy['server'], equals('example.com'));
        expect(proxy['port'], equals(443));
        expect(proxy['password'], equals('password123'));
        expect(proxy['name'], equals('MyTrojan'));
        expect(proxy['sni'], equals('sni.example.com'));
      });

      test('parses trojan link with insecure flag', () {
        final uri = 'trojan://pass@host:443?insecure=1#Test';
        final proxy = SubscriptionParser.proxyFromUri(uri);
        expect(proxy, isNotNull);
        expect(proxy!['skip-cert-verify'], isTrue);
      });

      test('parses anytls link', () {
        final uri = 'anytls://secret@server.io:8443?fp=chrome#Node1';
        final proxy = SubscriptionParser.proxyFromUri(uri);
        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('anytls'));
        expect(proxy['server'], equals('server.io'));
        expect(proxy['port'], equals(8443));
        expect(proxy['client-fingerprint'], equals('chrome'));
      });

      test('parses ss link', () {
        final uri = 'ss://aes-256-gcm:pass123@1.2.3.4:8388#MySS';
        final proxy = SubscriptionParser.proxyFromUri(uri);
        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('ss'));
        expect(proxy['server'], equals('1.2.3.4'));
        expect(proxy['port'], equals(8388));
        expect(proxy['cipher'], equals('aes-256-gcm'));
        expect(proxy['password'], equals('pass123'));
      });

      test('parses ss link with Base64 user info', () {
        final credentials = base64Url
            .encode(utf8.encode('chacha20-ietf-poly1305:secret'))
            .replaceAll('=', '');
        final uri = 'ss://$credentials@example.com:8388#EncodedSS';
        final proxy = SubscriptionParser.proxyFromUri(uri);
        expect(proxy, isNotNull);
        expect(proxy!['cipher'], equals('chacha20-ietf-poly1305'));
        expect(proxy['password'], equals('secret'));
      });

      test('returns null for unsupported scheme', () {
        final proxy = SubscriptionParser.proxyFromUri('ftp://example.com');
        expect(proxy, isNull);
      });

      test('returns null for invalid URI', () {
        final proxy = SubscriptionParser.proxyFromUri('not a uri');
        expect(proxy, isNull);
      });

      test('generates name from host:port when fragment is empty', () {
        final uri = 'trojan://pass@host.example:443';
        final proxy = SubscriptionParser.proxyFromUri(uri);
        expect(proxy, isNotNull);
        expect(proxy!['name'], equals('host.example:443'));
      });
    });

    group('uriListToYaml', () {
      test('parses multiple URIs', () {
        final content = '''
trojan://pass1@server1.com:443#Node1
trojan://pass2@server2.com:443#Node2
''';
        final yaml = SubscriptionParser.uriListToYaml(content);
        expect(yaml, isNotNull);
        expect(yaml, contains('proxies:'));
        expect(yaml, contains('server1.com'));
        expect(yaml, contains('server2.com'));
      });

      test('skips comments and empty lines', () {
        final content = '''
# This is a comment
trojan://pass@host:443#Node

# Another comment
''';
        final yaml = SubscriptionParser.uriListToYaml(content);
        expect(yaml, isNotNull);
        expect(yaml, contains('Node'));
      });

      test('returns null for empty content', () {
        expect(SubscriptionParser.uriListToYaml(''), isNull);
        expect(SubscriptionParser.uriListToYaml('# only comments'), isNull);
      });
    });

    group('parseSubscriptionContent', () {
      test('detects Clash YAML format', () {
        final yaml = '''
proxies:
  - name: Node1
    type: ss
    server: 1.2.3.4
    port: 443
''';
        final result = SubscriptionParser.parseSubscriptionContent(yaml);
        expect(result, isNotNull);
        expect(result, contains('proxies:'));
      });

      test('detects URI list format', () {
        final content = '''
trojan://pass@server1.com:443#N1
trojan://pass@server2.com:443#N2
''';
        final result = SubscriptionParser.parseSubscriptionContent(content);
        expect(result, isNotNull);
        expect(result, contains('server1.com'));
      });

      test('detects Base64-encoded URI list', () {
        final uris = 'trojan://pass@s1.com:443#N1\ntrojan://pass@s2.com:443#N2';
        final encoded = base64Encode(utf8.encode(uris));
        final result = SubscriptionParser.parseSubscriptionContent(encoded);
        expect(result, isNotNull);
        expect(result, contains('s1.com'));
      });

      test('returns null for garbage input', () {
        expect(SubscriptionParser.parseSubscriptionContent(''), isNull);
        expect(SubscriptionParser.parseSubscriptionContent('xyz'), isNull);
      });
    });

    group('uniqueProxyName', () {
      test('returns original name if unique', () {
        final used = <String>{};
        expect(
          SubscriptionParser.uniqueProxyName('Node1', used),
          equals('Node1'),
        );
      });

      test('appends suffix on collision', () {
        final used = <String>{'Node1'};
        expect(
          SubscriptionParser.uniqueProxyName('Node1', used),
          equals('Node1 (2)'),
        );
      });

      test('increments suffix until unique', () {
        final used = <String>{'Node1', 'Node1 (2)'};
        expect(
          SubscriptionParser.uniqueProxyName('Node1', used),
          equals('Node1 (3)'),
        );
      });
    });

    group('deduplicateProxies', () {
      test('removes exact duplicates', () {
        final proxies = [
          {'name': 'A', 'server': 's', 'port': 443},
          {'name': 'A', 'server': 's', 'port': 443},
          {'name': 'B', 'server': 's', 'port': 443},
        ];
        final result = SubscriptionParser.deduplicateProxies(proxies);
        expect(result, hasLength(2));
      });

      test('keeps same name but different server', () {
        final proxies = [
          {'name': 'A', 'server': 's1', 'port': 443},
          {'name': 'A', 'server': 's2', 'port': 443},
        ];
        final result = SubscriptionParser.deduplicateProxies(proxies);
        expect(result, hasLength(2));
      });
    });

    group('tryDecodeBase64', () {
      test('decodes Base64 content', () {
        final encoded =
            base64Encode(utf8.encode('Hello World, this is a test message'));
        final result = SubscriptionParser.tryDecodeBase64(encoded);
        expect(result, equals('Hello World, this is a test message'));
      });

      test('returns original for non-Base64', () {
        final result = SubscriptionParser.tryDecodeBase64('Hello World');
        expect(result, equals('Hello World'));
      });
    });

    group('cross-platform consistency', () {
      test('same subscription input produces same nodes', () {
        final yaml = '''
proxies:
  - name: "HK-01"
    type: ss
    server: hk1.example.com
    port: 443
    cipher: aes-256-gcm
    password: "key123"
  - name: "JP-01"
    type: trojan
    server: jp1.example.com
    port: 443
    password: "pass456"
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "HK-01"
      - "JP-01"
''';
        final result1 = SubscriptionParser.parseYaml(yaml);
        final result2 = SubscriptionParser.parseYaml(yaml);

        // Deterministic: same input → same output
        expect(result1.nodes.length, equals(result2.nodes.length));
        for (var i = 0; i < result1.nodes.length; i++) {
          expect(result1.nodes[i].name, equals(result2.nodes[i].name));
          expect(result1.nodes[i].server, equals(result2.nodes[i].server));
          expect(result1.nodes[i].port, equals(result2.nodes[i].port));
        }
      });

      test('URI list parsing is deterministic', () {
        final content =
            'trojan://pass@server.com:443#Node\ntrojan://pass@server2.com:443#Node';
        final yaml1 = SubscriptionParser.uriListToYaml(content);
        final yaml2 = SubscriptionParser.uriListToYaml(content);
        expect(yaml1, equals(yaml2));
      });
    });
  });

  group('LogRedactor', () {
    test('redacts passwords in YAML', () {
      const yaml = 'password: "mySecret123"';
      final redacted = LogRedactor.sanitize(yaml);
      expect(redacted, isNot(contains('mySecret123')));
      expect(redacted, contains('***'));
    });

    test('redacts Bearer tokens', () {
      const text = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc';
      final redacted = LogRedactor.sanitize(text);
      expect(redacted, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
    });

    test('redacts apiSecret fields', () {
      const text = 'secret: "super_secret_value"';
      final redacted = LogRedactor.sanitize(text);
      expect(redacted, isNot(contains('super_secret_value')));
    });

    test('preserves non-sensitive content', () {
      const text = 'server: example.com, port: 443';
      final redacted = LogRedactor.sanitize(text);
      expect(redacted, contains('example.com'));
      expect(redacted, contains('443'));
    });
  });
}
