import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_node_editor.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';

const _valid = {
  'name': 'Valid',
  'type': 'ss',
  'server': '127.0.0.1',
  'port': 443,
  'cipher': 'aes-128-gcm',
  'password': 'fixture',
};

void main() {
  final invalid = <Map<String, Object?>>[
    {'cipher': 'not-a-cipher'},
    {'password': true},
    {'cipher': '2022-blake3-aes-128-gcm', 'password': 'fixture'},
    {
      'cipher': '2022-blake3-aes-128-gcm',
      'password': base64Encode(List.filled(32, 1)),
    },
    {
      'cipher': '2022-blake3-chacha20-poly1305',
      'password': List.filled(2, base64Encode(List.filled(32, 1))).join(':'),
    },
    {
      'cipher': '2022-blake3-aes-128-gcm',
      'password': base64Encode(List.filled(16, 1)).replaceAll('=', ''),
    },
    {
      'cipher': '2022-blake3-aes-128-gcm',
      'password': base64UrlEncode(List.filled(16, 255)),
    },
    {
      'cipher': '2022-blake3-aes-128-gcm',
      'password': '${base64Encode(List.filled(16, 1))}:broken',
    },
    for (final type in ['trojan', 'anytls', 'hysteria2'])
      {'type': type, 'password': true},
    for (final type in ['vmess', 'vless']) {'type': type, 'uuid': true},
    {'type': 'hysteria', 'auth-str': true},
    {'type': 'tuic', 'token': true},
    {'type': 'snell', 'psk': true},
    {
      'plugin': 'restls',
      'plugin-opts': {
        'host': 'localhost',
        'password': 'fixture',
        'version-hint': 'bad',
      },
    },
    for (final plugin in ['v2ray-plugin', 'gost-plugin']) ...[
      {'plugin': plugin},
      {'plugin': plugin, 'plugin-opts': true},
      {
        'plugin': plugin,
        'plugin-opts': {'mode': 'quic'}
      },
      for (final option in ['host', 'path', 'tls', 'mux', 'headers'])
        {
          'plugin': plugin,
          'plugin-opts': {
            'mode': 'websocket',
            option: [true]
          }
        },
    ],
    {
      'plugin': 'obfs',
      'plugin-opts': {'host': 'localhost'}
    },
    {
      'plugin': 'obfs',
      'plugin-opts': {'mode': 'tls', 'host': true}
    },
    {
      'plugin': 'shadow-tls',
      'plugin-opts': {'host': true, 'version': 3}
    },
    {
      'plugin': 'shadow-tls',
      'plugin-opts': {
        'host': 'localhost',
        'alpn': [true]
      }
    },
    {
      'plugin': 'kcptun',
      'plugin-opts': {'mtu': true}
    },
    {
      'plugin': 'kcptun',
      'plugin-opts': {'mtu': 'bogus'}
    },
    {
      'plugin': 'kcptun',
      'plugin-opts': {'nocomp': 'maybe'}
    },
    for (final value in ['true', 'false', '1', 0])
      {
        'plugin': 'kcptun',
        'plugin-opts': {'nocomp': value}
      },
    for (final ports in ['bad', '0', '65536', '5000-4000', '443,,444', true])
      {'type': 'hysteria2', 'ports': ports},
    for (final interval in ['bad', '-1', '20-10', '9223372037', true])
      {'type': 'hysteria2', 'ports': '443,444', 'hop-interval': interval},
  ];

  for (var i = 0; i < invalid.length; i++) {
    test('YAML transport case $i cannot poison healthy siblings or node edits',
        () {
      final bad = {..._valid, ...invalid[i], 'name': 'Bad'};
      final yaml = jsonEncode({
        'proxies': [bad, _valid]
      });
      expect(SubscriptionParser.parseYaml(yaml).nodes.map((n) => n.name),
          ['Valid']);
      final runtime = ClashConfigGenerator.buildProxiesText(yaml);
      expect(runtime, contains('Valid'));
      expect(runtime, isNot(contains('Bad')));
      expect(
          () => SubscriptionNodeEditor.prepare(
              jsonEncode({
                'proxies': [_valid]
              }),
              'Valid',
              bad),
          throwsFormatException);
    });
  }

  test('valid structured YAML options remain intact', () {
    final proxies = [
      {
        ..._valid,
        'name': 'SS2022',
        'cipher': '2022-blake3-aes-128-gcm',
        'password': List.filled(2, base64Encode(List.filled(16, 1))).join(':'),
      },
      {
        ..._valid,
        'name': 'WS',
        'plugin': 'v2ray-plugin',
        'plugin-opts': {
          'mode': 'websocket',
          'host': 'localhost',
          'tls': true,
          'mux': false,
          'headers': {'Host': 'localhost'},
        }
      },
      {
        ..._valid,
        'name': 'KCP',
        'plugin': 'kcptun',
        'plugin-opts': {
          'mtu': 1350,
          'key': 'fixture',
          'nocomp': false,
        }
      },
      {
        ..._valid,
        'name': 'HY2',
        'type': 'hysteria2',
        'ports': '443,5000-6000',
        'hop-interval': 5
      },
    ];
    final yaml = jsonEncode({'proxies': proxies});
    expect(SubscriptionParser.parseYaml(yaml).nodes.length, proxies.length);
    final runtime = ClashConfigGenerator.buildProxiesText(yaml);
    for (final proxy in proxies) {
      expect(runtime, contains(proxy['name']! as String));
    }
    expect(runtime, contains('headers'));
  });

  test('URI credentials and Restls version use the same runtime validation',
      () {
    for (final uri in [
      'ss://not-a-cipher:fixture@127.0.0.1:443',
      'ss://2022-blake3-aes-128-gcm:fixture@127.0.0.1:443',
      'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin='
          '${Uri.encodeComponent('restls;host=localhost;password=fixture;version-hint=bad')}',
    ]) {
      expect(SubscriptionParser.proxyFromUri(uri), isNull, reason: uri);
    }
    final numeric = jsonEncode({
      'proxies': [
        {..._valid, 'password': 12345}
      ]
    });
    expect(SubscriptionParser.parseYaml(numeric).nodes.single.name, 'Valid');
  });
}
