import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_node_editor.dart';

void main() {
  for (final mode in [
    '',
    'auto',
    'packet-up',
    'stream-up',
    'stream-one',
    'invalid',
    'AUTO'
  ]) {
    test('XHTTP mode $mode matches core validation without losing siblings',
        () {
      final accepted = mode != 'invalid' && mode != 'AUTO';
      final proxy = SubscriptionParser.proxyFromUri(
          'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=xhttp&mode=$mode')!
        ..['name'] = 'Fixture';
      const healthy = {
        'name': 'Healthy',
        'type': 'socks5',
        'server': '127.0.0.1',
        'port': 1080,
      };
      final yaml = jsonEncode({
        'proxies': [proxy, healthy],
      });
      expect(SubscriptionParser.parseYaml(yaml).nodes.map((node) => node.name),
          accepted ? ['Fixture', 'Healthy'] : ['Healthy']);
      final runtime = ClashConfigGenerator.buildProxiesText(yaml);
      expect(runtime.contains('"Fixture"'), accepted);
      expect(runtime, contains('"Healthy"'));
      if (!accepted) {
        expect(
            () => SubscriptionNodeEditor.prepare(
                jsonEncode({
                  'proxies': [healthy]
                }),
                'Healthy',
                proxy),
            throwsFormatException);
      }
    });
  }
  for (final protocol in ['vless', 'trojan', 'vmess']) {
    test('$protocol HTTPUpgrade keeps handshake options in runtime config', () {
      final link = protocol == 'vmess'
          ? 'vmess://${base64Encode(utf8.encode(jsonEncode({
                  'add': 'example.invalid',
                  'port': 443,
                  'id': '00000000-0000-4000-8000-000000000001',
                  'net': 'httpupgrade',
                  'host': 'cdn.example.invalid',
                  'path': '/upgrade?token=fixture',
                  'tls': 'tls',
                  'sni': 'tls.example.invalid',
                })))}'
          : '$protocol://00000000-0000-4000-8000-000000000001@example.invalid:443?type=httpupgrade&host=cdn.example.invalid&path=%2Fupgrade%3Ftoken%3Dfixture&security=tls&sni=tls.example.invalid';
      final proxy = SubscriptionParser.proxyFromUri(link)!;
      expect(proxy['network'], 'ws');
      expect(proxy['ws-opts'], {
        'path': '/upgrade?token=fixture',
        'headers': {'Host': 'cdn.example.invalid'},
        'v2ray-http-upgrade': true,
      });
      final runtime = SubscriptionParser.parseYaml(
        ClashConfigGenerator.generateConfig(
            SubscriptionParser.uriListToYaml(link)!, AppSettings()),
      ).nodes.single;
      expect(runtime.extra['network'], 'ws');
      expect(runtime.extra['ws-opts'], proxy['ws-opts']);
      final sniKey = protocol == 'trojan' ? 'sni' : 'servername';
      expect(runtime.extra[sniKey], 'tls.example.invalid');
      if (protocol != 'trojan') {
        expect(runtime.extra['tls'], isTrue);
      }
      expect(runtime.extra['skip-cert-verify'], isNot(true));
    });
  }
  test('ordinary WS does not enable HTTPUpgrade', () {
    final proxy = SubscriptionParser.proxyFromUri(
        'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&path=%2Fws')!;
    expect(proxy['network'], 'ws');
    expect((proxy['ws-opts'] as Map)['v2ray-http-upgrade'], isNull);
  });
  test('VLESS XHTTP keeps path, host and mode in runtime config', () {
    const link =
        'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=xhttp&host=cdn.example.invalid&path=%2Fxhttp%2F&mode=packet-up&security=tls&sni=tls.example.invalid';
    final proxy = SubscriptionParser.proxyFromUri(link)!;
    expect(proxy['xhttp-opts'], {
      'path': '/xhttp/',
      'host': 'cdn.example.invalid',
      'mode': 'packet-up',
    });
    final runtime = SubscriptionParser.parseYaml(
      ClashConfigGenerator.generateConfig(
          SubscriptionParser.uriListToYaml(link)!, AppSettings()),
    ).nodes.single;
    expect(runtime.extra['network'], 'xhttp');
    expect(runtime.extra['xhttp-opts'], proxy['xhttp-opts']);
    expect(runtime.extra['tls'], isTrue);
    expect(runtime.extra['servername'], 'tls.example.invalid');
    expect(runtime.extra['skip-cert-verify'], isNot(true));
  });
  for (final cipher in ['zero', 'aes-128-cfb']) {
    test('valid VMess $cipher cipher survives YAML import', () {
      final parsed = SubscriptionParser.parseYaml(
          'proxies:\n  - {name: Test, type: vmess, server: example.invalid, port: 443, uuid: 00000000-0000-4000-8000-000000000001, alterId: 0, cipher: $cipher}\n');
      expect(parsed.nodes.length, 1);
    });
  }

  test('H2 import preserves its dedicated path and host options', () {
    final link = 'vmess://${base64Encode(utf8.encode(jsonEncode({
          'v': '2',
          'ps': 'Test',
          'add': 'example.invalid',
          'port': '443',
          'id': '00000000-0000-4000-8000-000000000001',
          'aid': '0',
          'net': 'h2',
          'tls': 'tls',
          'host': 'cdn.example.invalid',
          'path': '/tunnel'
        })))}';
    final proxy = SubscriptionParser.proxyFromUri(link)!;
    expect(proxy['h2-opts'], {
      'host': ['cdn.example.invalid'],
      'path': '/tunnel'
    });
  });
  for (final network in ['http', 'h2', '%20HTTP%20']) {
    test('VLESS $network imports HTTP/2 with its runtime options', () {
      final link =
          'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=$network&host=cdn.example.invalid&path=%2Ftunnel&security=tls&sni=tls.example.invalid';
      final proxy = SubscriptionParser.proxyFromUri(link)!;
      expect(proxy['network'], 'h2');
      expect(proxy['h2-opts'], {
        'host': ['cdn.example.invalid'],
        'path': '/tunnel',
      });
      expect(proxy['http-opts'], isNull);
      final runtime = SubscriptionParser.parseYaml(
        ClashConfigGenerator.generateConfig(
            SubscriptionParser.uriListToYaml(link)!, AppSettings()),
      ).nodes.single;
      expect(runtime.extra['network'], 'h2');
      expect(runtime.extra['h2-opts'], proxy['h2-opts']);
      expect(runtime.extra['tls'], isTrue);
      expect(runtime.extra['servername'], 'tls.example.invalid');
      expect(runtime.extra['skip-cert-verify'], isNot(true));
    });
  }
  test('VMess TCP HTTP camouflage survives import and runtime generation', () {
    final link = 'vmess://${base64Encode(utf8.encode(jsonEncode({
          'add': 'example.invalid',
          'port': 443,
          'id': '00000000-0000-4000-8000-000000000001',
          'net': 'tcp',
          'type': 'http',
          'host': 'cdn.example.invalid,edge.example.invalid',
          'path': '/tunnel',
          'tls': 'tls',
          'sni': 'tls.example.invalid',
        })))}';
    final proxy = SubscriptionParser.proxyFromUri(link)!;
    expect(proxy['network'], 'http');
    expect(proxy['http-opts'], {
      'path': ['/tunnel'],
      'headers': {
        'Host': ['cdn.example.invalid', 'edge.example.invalid']
      }
    });
    expect(proxy['tls'], isTrue);
    expect(proxy['servername'], 'tls.example.invalid');
    expect(proxy['skip-cert-verify'], isNull);
    final yaml = SubscriptionParser.uriListToYaml(link)!;
    final runtime = SubscriptionParser.parseYaml(
      ClashConfigGenerator.generateConfig(yaml, AppSettings()),
    ).nodes.single;
    expect(runtime.extra['network'], 'http');
    expect(runtime.extra['http-opts'], proxy['http-opts']);
    expect(runtime.extra['tls'], isTrue);
    expect(runtime.extra['servername'], 'tls.example.invalid');
    expect(runtime.extra['skip-cert-verify'], isNot(true));
  });
  for (final (network, camouflage, expected) in [
    ('tcp', 'none', 'tcp'),
    ('ws', 'http', 'ws'),
    ('kcp', 'http', 'kcp'),
    (' TCP ', ' HTTP ', 'http'),
  ]) {
    test('VMess $network/$camouflage preserves its transport boundary', () {
      final link = 'vmess://${base64Encode(utf8.encode(jsonEncode({
            'add': 'example.invalid',
            'port': 443,
            'id': '00000000-0000-4000-8000-000000000001',
            'net': network,
            'type': camouflage,
            'host': 'cdn.example.invalid',
            'path': '/tunnel',
          })))}';
      final proxy = SubscriptionParser.proxyFromUri(link)!;
      expect(proxy['network'], expected);
      if (expected != 'http') {
        expect(proxy['http-opts'], isNull);
      }
    });
  }
}
