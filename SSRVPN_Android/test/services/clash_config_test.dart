import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/services/clash_service.dart';

const _testProxies = '''
proxies:
  - name: 日本节点
    type: ss
    server: jp.example.com
    port: 443
    cipher: aes-256-gcm
    password: test
  - name: 新加坡节点
    type: ss
    server: sg.example.com
    port: 443
    cipher: aes-256-gcm
    password: test
  - name: 美国节点
    type: ss
    server: us.example.com
    port: 443
    cipher: aes-256-gcm
    password: test
''';

void main() {
  final clashService = ClashService();

  group('generateClashConfig — proxyMode 输出', () {
    test('规则模式 (rule) 生成 mode: rule', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(proxyMode: ProxyMode.rule),
      );

      expect(config, contains('mode: rule'));
    });

    test('全局模式 (global) 生成 mode: global', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(proxyMode: ProxyMode.global),
      );

      expect(config, contains('mode: global'));
    });
  });

  group('generateClashConfig — preferredNodeName', () {
    test('preferredNode 放在 PROXY 组第一位', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(),
        preferredNodeName: '新加坡节点',
      );

      final parsed = loadYaml(config) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == 'PROXY') as YamlMap;
      final proxies = (proxyGroup['proxies'] as YamlList).cast<String>();

      expect(proxies.first, '新加坡节点');
      expect(proxies, containsAll(['日本节点', '美国节点']));
    });

    test('不存在的 preferredNode 不影响其余节点', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(),
        preferredNodeName: '不存在的节点',
      );

      final parsed = loadYaml(config) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == 'PROXY') as YamlMap;
      final proxies = (proxyGroup['proxies'] as YamlList).cast<String>();

      expect(proxies.length, 3);
      expect(proxies, containsAll(['日本节点', '新加坡节点', '美国节点']));
    });
  });

  group('generateClashConfig — 结构完整性', () {
    test('输出为合法 YAML', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config);
      expect(parsed, isA<Map>());
    });

    test('包含必需字段', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      expect(parsed['mixed-port'], isA<int>());
      expect(parsed['socks-port'], isA<int>());
      expect(parsed['external-controller'], contains('127.0.0.1'));
      expect(parsed['tun'], isA<Map>());
      expect(parsed['dns'], isA<Map>());
      expect(parsed['proxies'], isNotEmpty);
      expect(parsed['proxy-groups'], isA<List>());
      expect(parsed['rules'], isA<List>());
    });

    test('TUN 始终启用（Android 必须）', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(enableTun: false),
      );

      final parsed = loadYaml(config) as YamlMap;
      expect(parsed['tun']['enable'], isTrue);
    });

    test('空订阅抛出异常', () {
      expect(
        () => clashService.generateClashConfig('', AppSettings()),
        throwsA(isA<Exception>()),
      );
      expect(
        () => clashService.generateClashConfig(
          'proxies: []',
          AppSettings(),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('包含 forceProxyRules 时规则正确', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(forceProxySites: ['example.com', '1.2.3.4']),
      );

      expect(config, contains('DOMAIN-SUFFIX,example.com'));
      expect(config, contains('IP-CIDR,1.2.3.4/32'));
    });

    test('MATCH 规则始终存在并指向 PROXY', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      expect(config, contains('MATCH,PROXY'));
    });
  });
}
