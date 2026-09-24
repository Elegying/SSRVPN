import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/services/subscription_node_editor.dart';

void main() {
  test('very long numeric options stay bounded and preserve leading zeroes',
      () {
    final vmess = {
      'name': 'probe',
      'type': 'vmess',
      'server': '127.0.0.1',
      'port': 443,
      'uuid': '00112233-4455-6677-8899-aabbccddeeff',
    };
    expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({
          ...vmess,
          'alterId': '0x${'0' * 100000}4',
        }),
        isTrue);
    expect(
        ProxyNodeUsagePolicy.isRunnableProxyMap({
          ...vmess,
          'alterId': '9' * 100000,
        }),
        isFalse);
  });

  // Outcomes obtained with the pinned Windows core, not with the validator.
  final fixtures = jsonDecode(
      File('test/fixtures/proxy_option_cases.json').readAsStringSync()) as List;
  const healthy = {
    'name': 'Healthy',
    'type': 'socks5',
    'server': '127.0.0.1',
    'port': 1080,
  };
  for (final fixture in fixtures) {
    final node = Map<String, dynamic>.from(fixture['node'] as Map);
    final accepted = fixture['accepted'] == true;
    test('optional fields match core loading: ${fixture['id']}', () {
      final yaml = jsonEncode({
        'proxies': [node, healthy]
      });
      expect(SubscriptionParser.parseYaml(yaml).nodes.map((n) => n.name),
          accepted ? ['probe', 'Healthy'] : ['Healthy']);
      final runtime = ClashConfigGenerator.buildProxiesText(yaml);
      expect(runtime, contains('Healthy'));
      expect(runtime.contains('"probe"'), accepted);
      if (fixture['expect_fields'] case final Map<Object?, Object?> fields) {
        final emitted =
            jsonDecode(runtime.split('\n').first.trim().substring(2)) as Map;
        for (final entry in fields.entries) {
          expect(emitted[entry.key], entry.value);
        }
      }
      // The editor intentionally accepts human-entered decimal numbers and
      // boolean text; YAML input preserves the core's original decoding rules.
      final editorCoerces = node.values.contains('false') ||
          node['alterId'] == '08' ||
          node['alterId'] == ' 4';
      if (!accepted && !editorCoerces) {
        expect(
            () => SubscriptionNodeEditor.prepare(
                jsonEncode({
                  'proxies': [healthy]
                }),
                'Healthy',
                node),
            throwsFormatException);
      }
    });
  }
}
