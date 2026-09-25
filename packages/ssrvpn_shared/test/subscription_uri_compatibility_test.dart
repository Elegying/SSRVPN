import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';

void main() {
  for (final (link, field) in [
    (
      'hy2://fixture@relay.invalid:443?obfs=salamander&obfs-password=%20fixture%20',
      'obfs-password'
    ),
    (
      'hysteria://relay.invalid:443?auth=%20fixture%20&upmbps=10&downmbps=50',
      'auth-str'
    ),
    (
      'hysteria://fixture@relay.invalid:443?obfs=%20fixture%20&upmbps=10&downmbps=50',
      'obfs'
    ),
    ('snell://%20fixture%20@relay.invalid:443?version=3', 'psk'),
    ('tuic://relay.invalid:443?token=%20fixture%20', 'token'),
    ('tuic://%20fixture%20@relay.invalid:443', 'token'),
  ]) {
    test('URI preserves opaque $field bytes: $link', () {
      final proxy = SubscriptionParser.proxyFromUri(link);
      expect(proxy, isNotNull);
      expect(proxy![field], ' fixture ');
      final yaml = SubscriptionParser.uriListToYaml(link)!;
      expect(SubscriptionParser.parseYaml(yaml).nodes.single.extra[field],
          ' fixture ');
    });
  }

  test('malformed UTF-8 query parameters cannot poison a mixed subscription',
      () {
    final invalid = [
      for (final scheme in ['ss', 'trojan', 'anytls', 'hy2', 'vless', 'tuic'])
        '$scheme://aes-128-gcm:fixture@host.test:443/?sni=%FF',
    ];
    for (final link in invalid) {
      expect(SubscriptionParser.proxyFromUri(link), isNull, reason: link);
    }
    final yaml = SubscriptionParser.uriListToYaml([
      ...invalid,
      'hy2://fixture@host.test#Valid',
    ].join('\n'))!;
    expect(SubscriptionParser.parseYaml(yaml).nodes.single.name, 'Valid');
  });

  test('SIP002 simple-obfs options become runnable Mihomo plugin options', () {
    final plugin =
        Uri.encodeComponent('obfs-local;obfs=tls;obfs-host=cdn.example.test');
    final node = SubscriptionParser.proxyFromUri(
      'ss://aes-128-gcm:fixture-password@relay.example.test:443/?plugin=$plugin#SS',
    )!;
    expect(node['plugin'], 'obfs');
    expect(node['plugin-opts'], {'mode': 'tls', 'host': 'cdn.example.test'});
  });

  test('SIP002 v2ray-plugin preserves transport options and escaped values',
      () {
    final plugin = Uri.encodeComponent(
      r'v2ray-plugin;tls;host=cdn.example.test;path=/edge\;v\=1;mode=websocket',
    );
    final node = SubscriptionParser.proxyFromUri(
      'ss://aes-128-gcm:fixture-password@relay.example.test:443/?plugin=$plugin',
    )!;
    expect(node['plugin'], 'v2ray-plugin');
    expect(node['plugin-opts'], {
      'tls': true,
      'host': 'cdn.example.test',
      'path': '/edge;v=1',
      'mode': 'websocket',
    });
  });

  test('legacy SS link decodes its endpoint without lowercasing credentials',
      () {
    final encoded = base64Encode(utf8.encode(
      'aes-128-gcm:CaseSensitive!@#:@relay.example.test:8388',
    ));
    final node = SubscriptionParser.proxyFromUri('ss://$encoded#Legacy%20SS');
    expect(node, isNotNull);
    expect(node!['password'], 'CaseSensitive!@#:');
    expect(node['server'], 'relay.example.test');
    expect(node['port'], 8388);
    expect(node['name'], 'Legacy SS');
  });

  test('HY2 authority port hopping preserves ranges and IPv6 endpoints', () {
    for (final server in ['relay.example.test', '[2001:db8::1]']) {
      final node = SubscriptionParser.proxyFromUri(
          'hy2://fixture@$server:443,5000-6000/?sni=tls.example.test#Hopping');
      expect(node, isNotNull);
      expect(node!['port'], 443);
      expect(node['ports'], '443,5000-6000');
      expect(node['server'], server.replaceAll(RegExp(r'[\[\]]'), ''));
    }
  });

  test('bad plugin options and ports do not discard valid sibling nodes', () {
    final invalid = [
      'ss://aes-128-gcm:fixture@host.test:0',
      'ss://aes-128-gcm:fixture@host.test:65536',
      'ss://not-base64#bad',
      for (final plugin in [
        'obfs-local;obfs=invalid',
        'unsupported;tls',
        'v2ray-plugin;tls=maybe',
        'v2ray-plugin;host=one;host=two',
        'v2ray-plugin;path=\\'
      ])
        'ss://aes-128-gcm:fixture@host.test:443/?plugin=${Uri.encodeComponent(plugin)}',
      for (final port in [
        '0',
        '65536',
        '443,0',
        '443,65536',
        '443,6000-5000',
        '443,,444',
        '443-444-445'
      ])
        'hy2://fixture@host.test:$port',
    ];
    for (final link in invalid) {
      expect(SubscriptionParser.proxyFromUri(link), isNull, reason: link);
    }
    final yaml = SubscriptionParser.uriListToYaml([
      ...invalid,
      'hy2://fixture@host.test#Valid',
    ].join('\n'))!;
    expect(SubscriptionParser.parseYaml(yaml).nodes.single.name, 'Valid');
  });

  test('legacy IPv6 and SIP002 percent encoding retain opaque credentials', () {
    final legacy =
        base64UrlEncode(utf8.encode('aes-128-gcm: %2B:@[2001:db8::1]:8388'))
            .replaceAll('=', '');
    expect(
        SubscriptionParser.proxyFromUri('ss://$legacy')!['password'], ' %2B:');
    final node = SubscriptionParser.proxyFromUri(
      'ss://aes-128-gcm:${Uri.encodeComponent(' +:@ ')}@[2001:db8::1]:8388',
    )!;
    expect(node['password'], ' +:@ ');
    expect(node['server'], '2001:db8::1');
  });

  test('HY2 share links without an explicit port use the protocol default', () {
    for (final scheme in ['hysteria2', 'hy2']) {
      final node = SubscriptionParser.proxyFromUri(
        '$scheme://fixture-password@relay.example.test/?sni=tls.example.test#HY2',
      );
      expect(node, isNotNull, reason: scheme);
      expect(node!['port'], 443);
      expect(node['password'], 'fixture-password');
    }
  });
}
