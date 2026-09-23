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
}
