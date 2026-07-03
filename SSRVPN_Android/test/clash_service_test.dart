import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import 'dart:io';
import 'package:ssrvpn_client/models/app_settings.dart';
import 'package:ssrvpn_client/services/clash_service.dart';

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
''';

void main() {
  group('ClashService Android config generation', () {
    test('generates valid YAML with TUN enabled', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;

      // Android TUN must always be true
      expect(parsed['tun']['enable'], isTrue);
      expect(parsed['tun']['stack'], isNotEmpty);
      expect(parsed['tun']['auto-route'], isTrue);

      // Core settings
      expect(parsed['mixed-port'], isA<int>());
      expect(parsed['socks-port'], isA<int>());
      expect(parsed['allow-lan'], isFalse);
      expect(parsed['ipv6'], isFalse);
      expect(parsed['external-controller'], contains('127.0.0.1'));
    });

    test('DNS fallback targets Google/Cloudflare', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final dns = parsed['dns'] as YamlMap;

      expect(dns['enhanced-mode'], 'fake-ip');
      expect(
        (dns['fallback'] as YamlList).cast<String>(),
        containsAll(['https://dns.google/dns-query', '8.8.8.8', '1.1.1.1']),
      );
      expect(
        (dns['nameserver'] as YamlList).cast<String>(),
        containsAll(['223.5.5.5', '119.29.29.29']),
      );
    });

    test('preferred node is placed first in PROXY group', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == 'PROXY') as YamlMap;
      final proxies = (proxyGroup['proxies'] as YamlList).cast<String>();

      expect(proxies, containsAll(['日本节点', '新加坡节点']));
    });

    test('preferred node config is persisted for tile cold starts', () async {
      final dir = await Directory.systemTemp.createTemp('ssrvpn_config_test_');
      addTearDown(() => dir.delete(recursive: true));
      final configPath = '${dir.path}${Platform.pathSeparator}config.yaml';
      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: configPath);

      await service.writePreferredNodeConfig(
        _testProxies,
        AppSettings(),
        '新加坡节点',
      );

      final parsed = loadYaml(await File(configPath).readAsString()) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == 'PROXY') as YamlMap;
      final proxies = (proxyGroup['proxies'] as YamlList).cast<String>();

      expect(proxies.first, '新加坡节点');
    });

    test('url-test group has correct ping URL and interval', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final autoGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == '自动选择') as YamlMap;

      expect(autoGroup['type'], 'url-test');
      expect(
        autoGroup['url'],
        'http://www.gstatic.com/generate_204',
      );
      expect(autoGroup['interval'], 300);
    });

    test('API secret is properly quoted in YAML', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(apiSecret: "test'secret"),
      );

      final parsed = loadYaml(config) as YamlMap;
      expect(parsed['secret'], "test'secret");
    });

    test('TUN route-exclude contains LAN CIDRs', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final excludes =
          (parsed['tun']['route-exclude-address'] as YamlList).cast<String>();

      expect(excludes, contains('192.168.0.0/16'));
      expect(excludes, contains('10.0.0.0/8'));
      expect(excludes, contains('172.16.0.0/12'));
    });

    test('fake-ip-filter excludes Google domains', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final filters =
          (parsed['dns']['fake-ip-filter'] as YamlList).cast<String>();

      expect(filters, contains('*.googlevideo.com'));
      expect(filters, contains('*.youtube.com'));
      expect(filters, contains('*.googleapis.com'));
    });
  });
}
