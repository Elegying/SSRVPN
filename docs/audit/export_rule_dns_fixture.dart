// Inspect actual production generator output; contains synthetic values only.
import 'dart:convert';

import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:yaml/yaml.dart';

void main() {
  final text = ClashConfigGenerator.generateConfig(
    'proxies: [{name: Synthetic, type: trojan, server: node.invalid, port: 443, password: synthetic}]',
    AppSettings(
      forceProxySites: ['example.com'],
      forceDirectSites: ['api.example.com'],
    ),
  );
  final config = loadYaml(text) as YamlMap;
  final dns = config['dns'] as YamlMap;
  final policies = dns['nameserver-policy'] as YamlMap;
  final rules = (config['rules'] as YamlList).cast<String>();
  final proxy = rules.indexOf('DOMAIN-SUFFIX,example.com,PROXY');
  final direct = rules.indexOf('DOMAIN-SUFFIX,api.example.com,DIRECT');
  if (proxy < 0 || direct <= proxy) {
    throw StateError('Expected production parent-proxy precedence');
  }
  print(jsonEncode({
    'parentProxyIndex': proxy,
    'childDirectIndex': direct,
    'parentDns': policies['+.example.com'],
    'childDns': policies['+.api.example.com'],
  }));
}
