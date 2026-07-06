import 'package:test/test.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';

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
          'https://www.google.com/search?q=test',
          '*.youtube.com',
          '192.168.0.1',
          '2001:db8::1',
          'example.com',
          'example.com',
        ],
      );

      final rules = ClashConfigGenerator.buildForceProxyRules(settings);
      expect(rules, hasLength(4));
      expect(rules[0], equals('DOMAIN-SUFFIX,www.google.com,PROXY'));
      expect(rules[1], equals('DOMAIN-SUFFIX,youtube.com,PROXY'));
      expect(rules[2], equals('IP-CIDR,192.168.0.1/32,PROXY,no-resolve'));
      expect(rules[3], equals('DOMAIN-SUFFIX,example.com,PROXY'));
    });

    test(
      'buildForceProxyRules normalizes full URLs and ignores bad entries',
      () {
        final rules = ClashConfigGenerator.buildForceProxyRulesFromSites([
          'https://User:Pass@Example.com:8443/path?q=1',
          'example.com',
          '*.Video.Example.COM',
          '1.2.3.4:443',
          '1.2.3.4',
          'bad_domain.example',
          'one.com two.com',
        ]);

        expect(rules, [
          'DOMAIN-SUFFIX,example.com,PROXY',
          'DOMAIN-SUFFIX,video.example.com,PROXY',
          'IP-CIDR,1.2.3.4/32,PROXY,no-resolve',
        ]);
      },
    );

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

    test('generateConfig writes saved force proxy sites before direct rules',
        () {
      final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';
      final settings = AppSettings(
        forceProxySites: [
          'https://Blocked.Example/path',
          '1.2.3.4:443',
        ],
      );

      final parsed =
          loadYaml(ClashConfigGenerator.generateConfig(yaml, settings))
              as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();

      expect(rules[0], 'DOMAIN-SUFFIX,blocked.example,PROXY');
      expect(rules[1], 'IP-CIDR,1.2.3.4/32,PROXY,no-resolve');
      expect(
        rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT'),
        greaterThan(1),
      );
      expect(
        rules.indexOf('DOMAIN-SUFFIX,cn,DIRECT'),
        greaterThan(rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT')),
      );
    });

    test('generateConfig enables externally refreshed CN rule providers', () {
      final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed =
          loadYaml(ClashConfigGenerator.generateConfig(yaml, AppSettings()))
              as YamlMap;
      final providers = parsed['rule-providers'] as YamlMap;
      final domainProvider = providers['ssrvpn-geosite-cn'] as YamlMap;
      final ipProvider = providers['ssrvpn-geoip-cn'] as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();

      expect(parsed['etag-support'], isTrue);
      expect(domainProvider['type'], 'http');
      expect(domainProvider['behavior'], 'domain');
      expect(domainProvider['format'], 'mrs');
      expect(domainProvider.containsKey('interval'), isFalse);
      expect(domainProvider['proxy'], 'PROXY');
      expect(
        domainProvider['url'],
        'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs',
      );
      expect(ipProvider['type'], 'http');
      expect(ipProvider['behavior'], 'ipcidr');
      expect(ipProvider['format'], 'mrs');
      expect(ipProvider.containsKey('interval'), isFalse);
      expect(ipProvider['proxy'], 'PROXY');
      expect(
        ipProvider['url'],
        'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs',
      );
      expect(
        rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT'),
        lessThan(rules.indexOf('MATCH,PROXY')),
      );
      expect(
        rules.indexOf('RULE-SET,ssrvpn-geoip-cn,DIRECT,no-resolve'),
        lessThan(rules.indexOf('MATCH,PROXY')),
      );
    });

    test('generateConfig safely quotes API secret', () {
      final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';
      final settings = AppSettings(apiSecret: 'a"b\\c\'d');

      final config = ClashConfigGenerator.generateConfig(yaml, settings);

      expect(config, contains("secret: 'a\"b\\\\c''d'"));
    });

    test('generateConfig safely rebuilds user-controlled proxy fields', () {
      final yaml = '''
proxies:
  # - name: "Commented Node"
  #   type: ss
  - name: "Node: one # primary"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "p: a # b"
  - name: "O'Brien"
    type: trojan
    server: example.org
    port: 443
    password: "sec'ret"
proxy-groups:
  - name: ignored
    proxies:
      - Commented Node
''';
      final config = ClashConfigGenerator.generateConfig(yaml, AppSettings());
      final parsed = loadYaml(config) as YamlMap;

      final proxies = (parsed['proxies'] as YamlList).cast<YamlMap>();
      expect(proxies, hasLength(2));
      expect(proxies[0]['name'], 'Node: one # primary');
      expect(proxies[0]['password'], 'p: a # b');
      expect(proxies[1]['name'], "O'Brien");
      expect(proxies[1]['password'], "sec'ret");

      final proxyGroup = (parsed['proxy-groups'] as YamlList).first as YamlMap;
      expect((proxyGroup['proxies'] as YamlList).cast<String>(), [
        'Node: one # primary',
        "O'Brien",
      ]);
    });

    test('generateConfig strips app-only proxy metadata', () {
      final yaml = '''
proxies:
  - name: "Node 1"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
    ssrvpn-subscription: "Feed A"
    group: "Feed A"
''';

      final config = ClashConfigGenerator.generateConfig(yaml, AppSettings());
      final parsed = loadYaml(config) as YamlMap;
      final proxy = (parsed['proxies'] as YamlList).single as YamlMap;

      expect(proxy.containsKey('ssrvpn-subscription'), isFalse);
      expect(proxy.containsKey('group'), isFalse);
    });

    test('generateConfig excludes subscription info pseudo nodes', () {
      final yaml = '''
proxies:
  - name: "套餐到期：长期有效"
    type: trojan
    server: expired.example.com
    port: 443
    password: "notice"
  - name: "剩余流量：993.95 GB"
    type: trojan
    server: traffic.example.com
    port: 443
    password: "notice"
  - name: "Japan 01"
    type: ss
    server: jp.example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
  - name: "US 01"
    type: ss
    server: us.example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed =
          loadYaml(ClashConfigGenerator.generateConfig(yaml, AppSettings()))
              as YamlMap;
      final proxies = (parsed['proxies'] as YamlList).cast<YamlMap>();
      final proxyGroups = (parsed['proxy-groups'] as YamlList).cast<YamlMap>();

      expect(proxies.map((proxy) => proxy['name']), ['Japan 01', 'US 01']);
      for (final group in proxyGroups) {
        final names = (group['proxies'] as YamlList).cast<String>();
        expect(names, isNot(contains('套餐到期：长期有效')));
        expect(names, isNot(contains('剩余流量：993.95 GB')));
      }
    });

    test('extractProxyNames ignores commented YAML nodes', () {
      final yaml = '''
proxies:
  # - name: "Commented Node"
  #   type: ss
  - name: "Active Node"
    type: ss
    server: example.com
    port: 443
''';

      expect(ClashConfigGenerator.extractProxyNames(yaml), ['Active Node']);
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
