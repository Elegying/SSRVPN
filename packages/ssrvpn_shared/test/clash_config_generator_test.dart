import 'package:test/test.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';

void main() {
  group('ClashConfigGenerator', () {
    test('extractProxyNames extracts names from YAML', () {
      final yaml = '''
proxies:
  - name: "Node 1"
    type: ss
    server: example.com
    port: 443
  - name: 'Node 2'
    type: ss
    server: example2.com
    port: 443
  - name: Node 3
    type: ss
    server: example3.com
    port: 443
''';
      final names = ClashConfigGenerator.extractProxyNames(yaml);
      expect(names, hasLength(3));
      expect(names[0], equals('Node 1'));
      expect(names[1], equals('Node 2'));
      expect(names[2], equals('Node 3'));
    });

    test('extractProxyNames returns empty for invalid YAML', () {
      final names = ClashConfigGenerator.extractProxyNames('invalid yaml');
      expect(names, isEmpty);
    });

    test('extractSection extracts proxies section', () {
      final yaml = '''
proxies:
  - name: "Node 1"
    type: ss
    server: example.com
    port: 443
proxy-groups:
  - name: "Group 1"
    type: select
''';
      final section = ClashConfigGenerator.extractSection(yaml, 'proxies');
      expect(section, contains('name: "Node 1"'));
      expect(section, contains('type: ss'));
      expect(section, isNot(contains('proxy-groups:')));
    });

    test('extractSection returns empty for missing section', () {
      final yaml = '''
proxies:
  - name: "Node 1"
''';
      final section = ClashConfigGenerator.extractSection(yaml, 'missing');
      expect(section, isEmpty);
    });

    test('buildForceProxyRules builds rules from settings', () {
      final settings = AppSettings(
        forceProxySites: [
          'DOMAIN-SUFFIX,google.com',
          'DOMAIN,youtube.com',
          'IP-CIDR,192.168.0.0/16',
          'example.com',
        ],
      );
      
      final rules = ClashConfigGenerator.buildForceProxyRules(settings);
      expect(rules, hasLength(4));
      expect(rules[0], equals('DOMAIN-SUFFIX,google.com,PROXY'));
      expect(rules[1], equals('DOMAIN,youtube.com,PROXY'));
      expect(rules[2], equals('IP-CIDR,192.168.0.0/16,PROXY,no-resolve'));
      expect(rules[3], equals('DOMAIN-SUFFIX,example.com,PROXY'));
    });

    test('generateConfig generates valid config', () {
      final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';
      final settings = AppSettings();
      
      final config = ClashConfigGenerator.generateConfig(yaml, settings);
      
      expect(config, contains('mixed-port: 7890'));
      expect(config, contains('socks-port: 7891'));
      expect(config, contains('allow-lan: false'));
      expect(config, contains('mode: rule'));
      expect(config, contains('ipv6: false'));
      expect(config, contains('proxies:'));
      expect(config, contains('proxy-groups:'));
      expect(config, contains('rules:'));
      expect(config, contains('Test Node'));
    });

    test('generateConfig throws for empty proxies', () {
      final yaml = '''
proxies:
''';
      final settings = AppSettings();
      
      expect(
        () => ClashConfigGenerator.generateConfig(yaml, settings),
        throwsException,
      );
    });

    test('generateConfig includes preferred node first', () {
      final yaml = '''
proxies:
  - name: "Node 1"
    type: ss
    server: example1.com
    port: 443
  - name: "Node 2"
    type: ss
    server: example2.com
    port: 443
''';
      final settings = AppSettings();
      
      final config = ClashConfigGenerator.generateConfig(
        yaml, 
        settings,
        preferredNodeName: 'Node 2',
      );
      
      // Node 2 should be first in PROXY group
      final proxyGroupStart = config.indexOf('- name: PROXY');
      final proxyGroupEnd = config.indexOf('- name: GLOBAL');
      final proxyGroup = config.substring(proxyGroupStart, proxyGroupEnd);
      
      final node2Index = proxyGroup.indexOf('Node 2');
      final node1Index = proxyGroup.indexOf('Node 1');
      
      expect(node2Index, lessThan(node1Index));
    });
  });
}
