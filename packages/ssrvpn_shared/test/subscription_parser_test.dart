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

      test('maps app-only subscription source to node group', () {
        final yaml = '''
proxies:
  - name: "Node 1"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: secret
    ssrvpn-subscription: "Feed A"
''';

        final result = SubscriptionParser.parseYaml(yaml);

        expect(result.nodes.single.group, 'Feed A');
        expect(result.nodes.single.extra['ssrvpn-subscription'], 'Feed A');
      });

      test('ignores subscription info pseudo nodes', () {
        final yaml = '''
proxies:
  - name: "套餐到期：长期有效"
    type: trojan
    server: expired.example.com
    port: 443
    password: "notice"
  - name: "剩余流量：993.95 GB"
    type: trojan
    server: traffic.example.com
    port: 443
    password: "notice"
  - name: "Real Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "套餐到期：长期有效"
      - "剩余流量：993.95 GB"
      - "Real Node"
''';

        final result = SubscriptionParser.parseYaml(yaml);

        expect(result.nodes.map((node) => node.name), ['Real Node']);
        expect(
          result.groups.single.nodes.map((node) => node.name),
          ['Real Node'],
        );
      });
    });

    test('accepts Clash YAML with comments and settings before proxies', () {
      const yaml = '''
# provider generated config
mixed-port: 7890
mode: rule
proxies:
  - name: Node A
    type: ss
    server: example.com
    port: 443
    cipher: aes-128-gcm
    password: secret
''';

      final parsed = SubscriptionParser.parseSubscriptionContent(yaml);

      expect(parsed, yaml);
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

      test('parses SSR links whose server is an IPv6 literal', () {
        final password =
            base64Url.encode(utf8.encode('testpassword')).replaceAll('=', '');
        final mainPart = '[2001:db8::10]:443:auth_aes128_md5:aes-256-cfb:'
            'tls1.2_ticket_auth:$password';
        final encoded =
            base64Url.encode(utf8.encode(mainPart)).replaceAll('=', '');

        final result = SubscriptionParser.importSsrLink('ssr://$encoded');

        expect(result, isNotNull);
        expect(result, contains('server: "2001:db8::10"'));
        expect(result, contains('port: 443'));
      });

      test('rejects ambiguous or zone-qualified SSR IPv6 servers', () {
        String encode(String value) =>
            base64Url.encode(utf8.encode(value)).replaceAll('=', '');

        for (final server in [
          '[2001:db8::10',
          'fe80::1%en0',
          '[example.com]',
        ]) {
          final mainPart = '$server:443:origin:aes-256-cfb:plain:'
              '${encode('password')}';
          expect(
            SubscriptionParser.importSsrLink('ssr://${encode(mainPart)}'),
            isNull,
          );
        }
      });

      test('rejects non-SSR links', () {
        expect(SubscriptionParser.importSsrLink('http://example.com'), isNull);
        expect(SubscriptionParser.importSsrLink(''), isNull);
      });
    });

    group('proxyFromUri', () {
      test('rejects zone-qualified and ambiguous IPv6 servers for every input',
          () {
        String vmess(String server) => 'vmess://${base64Encode(utf8.encode(
              jsonEncode({
                'add': server,
                'port': 443,
                'id': '00000000-0000-0000-0000-000000000001',
              }),
            ))}';

        for (final uri in [
          'trojan://pass@[fe80::1%25en0]:443',
          'vless://uuid@[fe80::1%25en0]:443',
          vmess('fe80::1%en0'),
          vmess('[2001:db8::1'),
        ]) {
          expect(SubscriptionParser.proxyFromUri(uri), isNull, reason: uri);
        }
      });

      test('accepts and normalizes VMess IPv6 literals', () {
        final uri = 'vmess://${base64Encode(utf8.encode(jsonEncode({
              'add': '[2001:db8::20]',
              'port': 443,
              'id': '00000000-0000-0000-0000-000000000001',
            })))}';

        expect(SubscriptionParser.proxyFromUri(uri)?['server'], '2001:db8::20');
      });

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

      test('parses vless websocket tls link', () {
        final uri = 'vless://uuid-1234@example.com:443'
            '?type=ws&security=tls&encryption=none'
            '&host=cdn.example.com&path=%2Fedge'
            '&sni=sni.example.com&fp=chrome&insecure=1#VLESS%20WS';
        final proxy = SubscriptionParser.proxyFromUri(uri);

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('vless'));
        expect(proxy['uuid'], equals('uuid-1234'));
        expect(proxy['network'], equals('ws'));
        expect(proxy['tls'], isTrue);
        expect(proxy['servername'], equals('sni.example.com'));
        expect(proxy['client-fingerprint'], equals('chrome'));
        expect(proxy['skip-cert-verify'], isTrue);
        expect(proxy['ws-opts']['path'], equals('/edge'));
        expect(proxy['ws-opts']['headers']['Host'], equals('cdn.example.com'));
      });

      test('parses vless reality link', () {
        final uri = 'vless://uuid-5678@reality.example.com:443'
            '?type=tcp&security=reality&flow=xtls-rprx-vision'
            '&sni=www.microsoft.com&fp=chrome&pbk=public-key&sid=abcd'
            '#VLESS%20Reality';
        final proxy = SubscriptionParser.proxyFromUri(uri);

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('vless'));
        expect(proxy['network'], equals('tcp'));
        expect(proxy['tls'], isTrue);
        expect(proxy['flow'], equals('xtls-rprx-vision'));
        expect(proxy['servername'], equals('www.microsoft.com'));
        expect(proxy['reality-opts']['public-key'], equals('public-key'));
        expect(proxy['reality-opts']['short-id'], equals('abcd'));
      });

      test('parses a bracketed IPv6 node URI', () {
        final proxy = SubscriptionParser.proxyFromUri(
          'vless://uuid-1234@[2001:db8::50]:443?encryption=none',
        );

        expect(proxy, isNotNull);
        expect(proxy!['server'], '2001:db8::50');
        expect(proxy['port'], 443);
        expect(proxy['name'], '[2001:db8::50]:443');
      });

      test('parses hysteria2 link', () {
        final uri = 'hysteria2://hy-pass@hy.example.com:443'
            '?mport=20000-30000&sni=hy-sni.example.com'
            '&insecure=1'
            '&pinSHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
            '&alpn=h3#HY2%20Node';
        final proxy = SubscriptionParser.proxyFromUri(uri);

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('hysteria2'));
        expect(proxy['password'], equals('hy-pass'));
        expect(proxy['ports'], equals('20000-30000'));
        expect(proxy['sni'], equals('hy-sni.example.com'));
        expect(proxy['skip-cert-verify'], isTrue);
        expect(
          proxy['fingerprint'],
          equals(
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          ),
        );
        expect(proxy['alpn'], equals(['h3']));
      });

      test('parses vmess json link', () {
        final payload = base64Encode(
          utf8.encode(
            jsonEncode({
              'v': '2',
              'ps': 'VMess WS',
              'add': 'vmess.example.com',
              'port': '443',
              'id': '00000000-0000-0000-0000-000000000001',
              'aid': '0',
              'scy': 'auto',
              'net': 'ws',
              'host': 'cdn.example.com',
              'path': '/ws',
              'tls': 'tls',
              'sni': 'sni.example.com',
              'fp': 'chrome',
            }),
          ),
        ).replaceAll('=', '');
        final proxy = SubscriptionParser.proxyFromUri('vmess://$payload');

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('vmess'));
        expect(proxy['name'], equals('VMess WS'));
        expect(proxy['server'], equals('vmess.example.com'));
        expect(proxy['port'], equals(443));
        expect(proxy['uuid'], equals('00000000-0000-0000-0000-000000000001'));
        expect(proxy['network'], equals('ws'));
        expect(proxy['tls'], isTrue);
        expect(proxy['ws-opts']['path'], equals('/ws'));
        expect(proxy['ws-opts']['headers']['Host'], equals('cdn.example.com'));
      });

      test('parses hysteria v1 link', () {
        final uri = 'hysteria://hy.example.com:443'
            '?auth=secret&protocol=udp&upmbps=20&downmbps=100'
            '&peer=hy-sni.example.com&insecure=1#Hysteria%20V1';
        final proxy = SubscriptionParser.proxyFromUri(uri);

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('hysteria'));
        expect(proxy['auth-str'], equals('secret'));
        expect(proxy['protocol'], equals('udp'));
        expect(proxy['up'], equals('20 Mbps'));
        expect(proxy['down'], equals('100 Mbps'));
        expect(proxy['sni'], equals('hy-sni.example.com'));
        expect(proxy['skip-cert-verify'], isTrue);
      });

      test('parses tuic link', () {
        final uri = 'tuic://00000000-0000-0000-0000-000000000001:pass'
            '@tuic.example.com:10443?congestion_control=bbr'
            '&udp_relay_mode=native&sni=tuic-sni.example.com'
            '&alpn=h3&allow_insecure=1#TUIC%20Node';
        final proxy = SubscriptionParser.proxyFromUri(uri);

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('tuic'));
        expect(proxy['uuid'], equals('00000000-0000-0000-0000-000000000001'));
        expect(proxy['password'], equals('pass'));
        expect(proxy['congestion-controller'], equals('bbr'));
        expect(proxy['udp-relay-mode'], equals('native'));
        expect(proxy['sni'], equals('tuic-sni.example.com'));
        expect(proxy['alpn'], equals(['h3']));
        expect(proxy['skip-cert-verify'], isTrue);
      });

      test('parses snell link', () {
        final uri = 'snell://psk-value@snell.example.com:44046'
            '?version=4&obfs=tls&host=bing.com&udp=1#Snell%20Node';
        final proxy = SubscriptionParser.proxyFromUri(uri);

        expect(proxy, isNotNull);
        expect(proxy!['type'], equals('snell'));
        expect(proxy['psk'], equals('psk-value'));
        expect(proxy['version'], equals(4));
        expect(proxy['udp'], isTrue);
        expect(proxy['obfs-opts']['mode'], equals('tls'));
        expect(proxy['obfs-opts']['host'], equals('bing.com'));
      });

      test('parses socks and http proxy links with explicit ports', () {
        final socks = SubscriptionParser.proxyFromUri(
          'socks5://user:pass@socks.example.com:1080#Socks%20Node',
        );
        final http = SubscriptionParser.proxyFromUri(
          'https://user:pass@http.example.com:8443?insecure=1#HTTP%20Node',
        );

        expect(socks, isNotNull);
        expect(socks!['type'], equals('socks5'));
        expect(socks['username'], equals('user'));
        expect(socks['password'], equals('pass'));
        expect(http, isNotNull);
        expect(http!['type'], equals('http'));
        expect(http['tls'], isTrue);
        expect(http['skip-cert-verify'], isTrue);
      });

      test('does not treat ordinary http urls as proxy nodes', () {
        final proxy = SubscriptionParser.proxyFromUri(
          'https://example.com/subscription',
        );
        expect(proxy, isNull);
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

      test('round-trips quoted backslash and newline values through YAML', () {
        const password = 'pa"ss\\word\nnext';
        const path = '/edge"\\branch\nnext';
        final content = [
          'trojan://${Uri.encodeComponent(password)}@trojan.example.com:443'
              '#Trojan',
          'vless://uuid-1234@vless.example.com:443?type=ws'
              '&path=${Uri.encodeQueryComponent(path)}#VLESS',
        ].join('\n');

        final yaml = SubscriptionParser.uriListToYaml(content);
        final parsed = SubscriptionParser.parseYaml(yaml!);

        expect(parsed.nodes, hasLength(2));
        expect(parsed.nodes.first.extra['password'], password);
        expect(parsed.nodes.last.extra['ws-opts']['path'], path);
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

      test('detects Base64-encoded vless and hysteria2 URI list', () {
        final vmessPayload = base64Encode(
          utf8.encode(
            jsonEncode({
              'v': '2',
              'ps': 'VMess WS',
              'add': 'vmess.example.com',
              'port': '443',
              'id': '00000000-0000-0000-0000-000000000001',
              'aid': '0',
              'net': 'ws',
              'host': 'cdn.example.com',
              'path': '/ws',
              'tls': 'tls',
            }),
          ),
        ).replaceAll('=', '');
        final uris = '''
vmess://$vmessPayload
vless://uuid-1234@vless.example.com:443?type=ws&security=tls&encryption=none&host=cdn.example.com&path=%2Fedge&sni=sni.example.com&fp=chrome#VLESS%20WS
hysteria2://hy-pass@hy.example.com:443?mport=20000-30000&sni=hy-sni.example.com&insecure=1#HY2%20Node
tuic://00000000-0000-0000-0000-000000000001:pass@tuic.example.com:10443?congestion_control=bbr&udp_relay_mode=native#TUIC%20Node
''';
        final encoded = base64Encode(utf8.encode(uris)).replaceAll('=', '');
        final result = SubscriptionParser.parseSubscriptionContent(encoded);

        expect(result, isNotNull);
        final parsed = SubscriptionParser.parseYaml(result!);
        expect(parsed.nodes.map((node) => node.type), [
          'vmess',
          'vless',
          'hysteria2',
          'tuic',
        ]);
        expect(parsed.nodes.first.name, 'VMess WS');
        expect(parsed.nodes.last.name, 'TUIC Node');
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
        final encoded = base64Encode(
          utf8.encode('Hello World, this is a test message'),
        );
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
