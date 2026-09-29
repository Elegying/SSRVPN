import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/utils/proxy_egress_policy.dart';

void main() {
  const declaration = '[{"server":"node.example.test","port":443,'
      '"protocol":"hysteria2","egress":"ipv4"}]';
  test('unchanged legacy link receives runtime-only operator policy', () {
    final link = 'hysteria2://synthetic@node.example.test:443/'
        '?insecure=1&pinSHA256=${'a' * 64}#node';
    final yaml = SubscriptionParser.parseSubscriptionContent(link)!;
    final before = SubscriptionParser.parseYaml(yaml).nodes.single;
    final runtime = ClashConfigGenerator.buildProxiesText(yaml,
        egressPolicy: ProxyEgressPolicy.fromJson(declaration));
    expect(runtime, contains('"ssrvpn-egress":"ipv4"'));
    final after = SubscriptionParser.parseYaml(yaml).nodes.single;
    expect(after.extra, before.extra);
    expect(after.extra, isNot(contains('ssrvpn-egress')));
    expect(after.extra['password'], 'synthetic');
    expect(after.extra['fingerprint'], 'a' * 64);
    expect(SubscriptionParser.parseSubscriptionContent(link), yaml);
  });

  test('only exact operator endpoint and protocol match; invalid data ignored',
      () {
    final policy = ProxyEgressPolicy.fromJson(declaration);
    for (final overrides in [
      {'server': 'other.example.test'},
      {'port': 444},
      {'type': 'trojan'},
      {'server': 'node.example.test.evil.test'},
    ]) {
      final node = <String, dynamic>{
        'server': 'node.example.test',
        'port': 443,
        'type': 'hysteria2',
        ...overrides,
      };
      policy.applyToRuntime(node);
      expect(node, isNot(contains('ssrvpn-egress')));
    }
    for (final input in [
      'not-json',
      '{}',
      declaration.replaceFirst('ipv4', 'ipv6'),
      declaration.replaceFirst('443', '0')
    ]) {
      final node = <String, dynamic>{
        'server': 'node.example.test',
        'port': 443,
        'type': 'hysteria2'
      };
      ProxyEgressPolicy.fromJson(input).applyToRuntime(node);
      expect(node, isNot(contains('ssrvpn-egress')));
    }
  });

  test('release operator declarations cover verified node without renaming it',
      () {
    final definitions = jsonDecode(
            File('../../config/ssrvpn-usage-defines.json').readAsStringSync())
        as Map;
    final policy =
        ProxyEgressPolicy.fromJson(definitions['SSRVPN_NODE_EGRESS'] as String);
    final node = <String, dynamic>{
      'server': 'vpn.ssrvpn.vip',
      'port': 19999,
      'type': 'hysteria2',
      'name': 'existing-user-name',
      'password': 'synthetic'
    };
    policy.applyToRuntime(node);
    expect(node['ssrvpn-egress'], 'ipv4');
    expect(node['name'], 'existing-user-name');
    expect(node['password'], 'synthetic');
  });
}
