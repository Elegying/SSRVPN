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

      final parsed = loadYaml(config) as YamlMap;
      final groups = (parsed['proxy-groups'] as YamlList).cast<YamlMap>();
      final global = groups.firstWhere((group) => group['name'] == 'GLOBAL');

      expect(parsed['mode'], 'global');
      expect((global['proxies'] as YamlList).first, 'PROXY');
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
      expect(parsed, isA<Map<Object?, Object?>>());
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
      expect(parsed['tun'], isA<Map<Object?, Object?>>());
      expect(parsed['dns'], isA<Map<Object?, Object?>>());
      expect(parsed['proxies'], isNotEmpty);
      expect(parsed['proxy-groups'], isA<List<Object?>>());
      expect(parsed['rules'], isA<List<Object?>>());
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

    test('智能模式使用 GFW 代理并最终默认直连', () {
      final config = clashService.generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();
      final gfw = rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY');
      final cn = rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT');

      expect(gfw, isNonNegative);
      expect(gfw, lessThan(cn));
      expect(rules.last, 'MATCH,DIRECT');
      expect(rules, isNot(contains('MATCH,PROXY')));
    });
  });
}
