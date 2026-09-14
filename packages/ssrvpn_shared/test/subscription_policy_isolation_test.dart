import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_processing.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/utils/bounded_yaml.dart';
import 'package:test/test.dart';

const _nodes = '''
proxies:
  - name: Test Node
    type: ss
    server: node.example.com
    port: 443
    cipher: aes-256-gcm
    password: test-password
''';

const _providerPolicy = '''
rules:
  - DOMAIN-SUFFIX,manual-proxy.example,DIRECT
  - DOMAIN-SUFFIX,manual-direct.example,REJECT
  - MATCH,DIRECT
rule-providers:
  injected: {type: http, url: 'https://provider.invalid/rules.yaml'}
proxy-providers:
  injected: {type: http, url: 'https://provider.invalid/nodes.yaml'}
proxy-groups:
  - {name: PROXY, type: select, proxies: [DIRECT]}
dns:
  nameserver: [https://provider.invalid/dns-query]
hosts: {manual-proxy.example: 127.0.0.1}
tun: {enable: false}
sniffer: {enable: false}
script: {code: injected-script}
mode: direct
allow-lan: true
external-controller: 0.0.0.0:9090
listeners: [{name: injected, type: mixed, port: 9999}]
''';

void main() {
  final settings = AppSettings(
    forceProxySites: ['manual-proxy.example'],
    forceDirectSites: ['manual-direct.example'],
  );

  for (final background in [false, true]) {
    test('import retains only nodes (background: $background)', () async {
      final padding = background
          ? '# ${'x' * SubscriptionProcessing.isolateThreshold}\n'
          : '';
      final result = await SubscriptionProcessing.mergeAndParse(
        ['$_nodes$_providerPolicy$padding'],
        ['Primary'],
        SubscriptionRefreshControl(timeout: const Duration(seconds: 30)),
        proxySourceKey: 'ssrvpn-subscription',
        standaloneGroupName: 'Standalone',
      );
      final document = BoundedYaml.load(result.yaml) as Map;
      expect(document.keys, ['proxies']);
      expect(result.parsed.nodes.single.server, 'node.example.com');
      expect(result.parsed.groups, isEmpty);
      expect(
        ClashConfigGenerator.generateConfig(result.yaml, settings),
        ClashConfigGenerator.generateConfig(_nodes, settings),
      );
    });
  }

  test('legacy cache policy cannot change client runtime configuration',
      () async {
    final result = await SubscriptionProcessing.parseSnapshot(
      '$_nodes$_providerPolicy',
      SubscriptionRefreshControl(timeout: const Duration(seconds: 30)),
      loadingCache: true,
    );
    expect(result.parseWarning, isNull);
    expect(result.runtimeText, ClashConfigGenerator.buildProxiesText(_nodes));
    expect(
      ClashConfigGenerator.generateConfig(result.yaml, settings),
      ClashConfigGenerator.generateConfig(_nodes, settings),
    );
  });
}
