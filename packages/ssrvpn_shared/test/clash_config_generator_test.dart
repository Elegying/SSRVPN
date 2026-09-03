import 'package:test/test.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/utils/runtime_config_name_policy.dart';

void main() {
  group('ClashConfigGenerator', () {
    test('large async generation is byte-for-byte equivalent', () async {
      final padding = List.filled(14000, '# keep UI responsive').join('\n');
      final yaml = '''
$padding
proxies:
  - name: Large Node
    type: ss
    server: large.example.com
    port: 443
    cipher: aes-128-gcm
    password: secret
''';
      expect(yaml.length, greaterThan(ClashConfigGenerator.isolateThreshold));
      final settings = AppSettings(proxyPort: 7897, socksPort: 7898);

      final synchronous = ClashConfigGenerator.generateConfig(yaml, settings);
      final asynchronous =
          await ClashConfigGenerator.generateConfigAsync(yaml, settings);

      expect(asynchronous, synchronous);
    });

    test('extractProxyNames extracts names from YAML', () {
      final yaml = '''
proxies:
  - name: "Node 1"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: secret
  - name: 'Node 2'
    type: ss
    server: example2.com
    port: 443
    cipher: aes-256-gcm
    password: secret
  - name: Node 3
    type: ss
    server: example3.com
    port: 443
    cipher: aes-256-gcm
    password: secret
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

    test('generateConfig rejects YAML instead of mixing fallback name paths',
        () {
      const yaml = r'''
proxies:
  - name: "Fallback\u0001Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: secret
broken: [
''';

      expect(
        () => ClashConfigGenerator.generateConfig(yaml, AppSettings()),
        throwsException,
      );
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
      expect(rules, hasLength(5));
      expect(rules[0], equals('DOMAIN-SUFFIX,www.google.com,PROXY'));
      expect(rules[1], equals('DOMAIN-SUFFIX,youtube.com,PROXY'));
      expect(rules[2], equals('IP-CIDR,192.168.0.1/32,PROXY,no-resolve'));
      expect(rules[3], equals('IP-CIDR6,2001:db8::1/128,PROXY,no-resolve'));
      expect(rules[4], equals('DOMAIN-SUFFIX,example.com,PROXY'));
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
          'https://[2001:db8::2]:8443/path',
          '[2001:db8::2]:443',
          'bad_domain.example',
          'one.com two.com',
        ]);

        expect(rules, [
          'DOMAIN-SUFFIX,example.com,PROXY',
          'DOMAIN-SUFFIX,video.example.com,PROXY',
          'IP-CIDR,1.2.3.4/32,PROXY,no-resolve',
          'IP-CIDR6,2001:db8::2/128,PROXY,no-resolve',
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
      final parsed = loadYaml(config) as YamlMap;
      final dns = parsed['dns'] as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();
      expect(parsed['ipv6'], isFalse);
      expect(dns['ipv6'], isFalse);
      expect(dns.containsKey('fake-ip-range6'), isFalse);
      expect(rules.first, 'IP-CIDR6,::/0,REJECT,no-resolve');
      expect(rules.last, 'MATCH,PROXY');
      expect(rules, isNot(contains('MATCH,DIRECT')));
      expect(config, contains('proxies:'));
      expect(config, contains('proxy-groups:'));
      expect(config, contains('rules:'));
      expect(config, contains('Test Node'));
    });

    test('IPv4-only runtime rejects IPv6 before normal routing', () {
      const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(forceProxySites: const ['2001:db8::1']),
        ),
      ) as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();

      expect(parsed['ipv6'], isFalse);
      expect(parsed['tcp-concurrent'], isTrue);
      expect(rules.first, 'IP-CIDR6,::/0,REJECT,no-resolve');
      final forcedIpv6Index =
          rules.indexOf('IP-CIDR6,2001:db8::1/128,PROXY,no-resolve');
      expect(forcedIpv6Index, greaterThan(0));
      expect(
        rules.indexOf('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'),
        greaterThan(forcedIpv6Index),
        reason: 'manual rules must precede automatic private routing',
      );
      expect(rules, contains('RULE-SET,ssrvpn-geosite-cn,DIRECT'));
      expect(rules, contains('GEOIP,CN,DIRECT'));
      expect(
        rules.indexOf('DOMAIN-SUFFIX,openai.com,PROXY'),
        lessThan(
          rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY'),
        ),
      );
      expect(
        rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY'),
        lessThan(
          rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT'),
        ),
      );
    });

    test('Telegram official IPv4 ranges proxy before direct fallbacks', () {
      const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(yaml, AppSettings()),
      ) as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();
      final gfwProxyIndex = rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY');

      for (final cidr in const [
        '91.108.56.0/22',
        '91.108.4.0/22',
        '91.108.8.0/22',
        '91.108.16.0/22',
        '91.108.12.0/22',
        '149.154.160.0/20',
        '91.105.192.0/23',
        '91.108.20.0/22',
        '185.76.151.0/24',
      ]) {
        final index = rules.indexOf('IP-CIDR,$cidr,PROXY,no-resolve');
        expect(index, isNonNegative, reason: cidr);
        expect(index, lessThan(gfwProxyIndex), reason: cidr);
      }
      expect(gfwProxyIndex, lessThan(rules.indexOf('GEOIP,CN,DIRECT')));
      expect(rules.last, 'MATCH,PROXY');
    });

    test('generateConfig enables bounded HTTP TLS and QUIC domain sniffing',
        () {
      const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: node.example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(yaml, AppSettings()),
      ) as YamlMap;
      final sniffer = parsed['sniffer'] as YamlMap;
      final sniff = sniffer['sniff'] as YamlMap;

      expect(sniffer['enable'], isTrue);
      expect(sniffer['force-dns-mapping'], isTrue);
      expect(sniffer['parse-pure-ip'], isTrue);
      expect(sniffer['override-destination'], isFalse);
      expect((sniff['HTTP'] as YamlMap)['ports'], [80, 8080]);
      expect(
        (sniff['HTTP'] as YamlMap)['override-destination'],
        isTrue,
      );
      expect((sniff['TLS'] as YamlMap)['ports'], [443, 8443]);
      expect((sniff['QUIC'] as YamlMap)['ports'], [443, 8443]);
    });

    test('OpenAI DNS and routing never fall through to domestic resolvers', () {
      const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: node.example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(yaml, AppSettings()),
      ) as YamlMap;
      final dns = parsed['dns'] as YamlMap;
      final nameservers = (dns['nameserver'] as YamlList).cast<String>();
      final proxyNameservers =
          (dns['proxy-server-nameserver'] as YamlList).cast<String>();
      final policy = dns['nameserver-policy'] as YamlMap;
      final policyKeys = policy.keys.cast<String>().toList();
      final rules = (parsed['rules'] as YamlList).cast<String>();

      expect(dns['respect-rules'], isTrue);
      expect(
        nameservers,
        everyElement(allOf(contains('#PROXY'), isNot(contains('alidns')))),
      );
      expect(proxyNameservers, contains('https://dns.alidns.com/dns-query'));
      for (final domain in [
        '+.chatgpt.com',
        '+.openai.com',
        '+.oaistatic.com',
        '+.oaiusercontent.com',
      ]) {
        final resolvers = (policy[domain] as YamlList).cast<String>();
        expect(resolvers, everyElement(contains('#PROXY')));
      }
      for (final rule in [
        'DOMAIN-SUFFIX,chatgpt.com,PROXY',
        'DOMAIN-SUFFIX,openai.com,PROXY',
        'DOMAIN-SUFFIX,oaistatic.com,PROXY',
        'DOMAIN-SUFFIX,oaiusercontent.com,PROXY',
      ]) {
        expect(rules, contains(rule));
        expect(
          rules.indexOf(rule),
          lessThan(rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY')),
        );
      }
      expect(
        policyKeys.indexOf('+.openai.com'),
        lessThan(policyKeys.indexOf('rule-set:ssrvpn-geosite-gfw')),
      );
    });

    test(
      'Google Play delivery never falls through to domestic DNS or routing',
      () {
        const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: node.example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

        final parsed = loadYaml(
          ClashConfigGenerator.generateConfig(yaml, AppSettings()),
        ) as YamlMap;
        final dns = parsed['dns'] as YamlMap;
        final policy = dns['nameserver-policy'] as YamlMap;
        final policyKeys = policy.keys.cast<String>().toList();
        final rules = (parsed['rules'] as YamlList).cast<String>();
        for (final domain in const [
          'services.googleapis.cn',
          'xn--ngstr-lra8j.com',
        ]) {
          final policyKey = '+.$domain';
          final proxyRuleIndex = rules.indexOf(
            'DOMAIN-SUFFIX,$domain,PROXY',
          );

          expect(
            (policy[policyKey] as YamlList).cast<String>(),
            everyElement(contains('#PROXY')),
          );
          expect(
            policyKeys.indexOf(policyKey),
            lessThan(policyKeys.indexOf('rule-set:ssrvpn-geosite-gfw')),
          );
          expect(
            policyKeys.indexOf('rule-set:ssrvpn-geosite-gfw'),
            lessThan(policyKeys.indexOf('rule-set:ssrvpn-geosite-cn')),
          );
          expect(proxyRuleIndex, isNonNegative);
          expect(
            proxyRuleIndex,
            lessThan(rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY')),
          );
          expect(proxyRuleIndex, lessThan(rules.indexOf('GEOIP,CN,DIRECT')));
        }
      },
    );

    test(
      'force-proxy domains override domestic DNS and routing without duplicates',
      () {
        const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: node.example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';
        final settings = AppSettings(
          forceProxySites: const [
            'https://shop.example.cn/path',
            'openai.com',
            '192.0.2.1',
          ],
        );

        final parsed = loadYaml(
          ClashConfigGenerator.generateConfig(yaml, settings),
        ) as YamlMap;
        final dns = parsed['dns'] as YamlMap;
        final policy = dns['nameserver-policy'] as YamlMap;
        final policyKeys = policy.keys.cast<String>().toList();
        final rules = (parsed['rules'] as YamlList).cast<String>();

        final forcedDomainIndex =
            rules.indexOf('DOMAIN-SUFFIX,shop.example.cn,PROXY');
        final forcedIpIndex =
            rules.indexOf('IP-CIDR,192.0.2.1/32,PROXY,no-resolve');
        final domesticDomainIndex =
            rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT');
        final gfwProxyIndex =
            rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY');
        final domesticIpIndex = rules.indexOf('GEOIP,CN,DIRECT');
        expect(forcedDomainIndex, isNonNegative);
        expect(forcedIpIndex, isNonNegative);
        expect(forcedDomainIndex, lessThan(gfwProxyIndex));
        expect(forcedIpIndex, lessThan(gfwProxyIndex));
        expect(gfwProxyIndex, lessThan(domesticDomainIndex));
        expect(forcedDomainIndex, lessThan(domesticIpIndex));
        expect(forcedIpIndex, lessThan(domesticIpIndex));

        final forcedResolvers =
            (policy['+.shop.example.cn'] as YamlList).cast<String>();
        expect(forcedResolvers, everyElement(contains('#PROXY')));
        expect(
            policyKeys.indexOf('+.shop.example.cn'),
            lessThan(
              policyKeys.indexOf('rule-set:ssrvpn-geosite-gfw'),
            ));
        expect(
            policyKeys.indexOf('rule-set:ssrvpn-geosite-gfw'),
            lessThan(
              policyKeys.indexOf('rule-set:ssrvpn-geosite-cn'),
            ));
        expect(
            policyKeys.indexOf('+.shop.example.cn'),
            lessThan(
              policyKeys.indexOf('+.cn'),
            ));
        expect(
          (policy['rule-set:ssrvpn-geosite-cn'] as YamlList).cast<String>(),
          containsAll([
            'https://dns.alidns.com/dns-query',
            'https://doh.pub/dns-query',
          ]),
        );
        expect(
          policyKeys.where((key) => key == '+.openai.com'),
          hasLength(1),
        );
        expect(policy.containsKey('+.192.0.2.1'), isFalse);
      },
    );

    test('generic TUN captures IPv6 only to reject it without bypass', () {
      const yaml = '''
proxies:
  - name: Test Node
    type: ss
    server: 2001:db8::10
    port: 443
    cipher: aes-256-gcm
    password: test123
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(enableTun: true),
        ),
      ) as YamlMap;
      final tun = parsed['tun'] as YamlMap;
      final dns = parsed['dns'] as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();
      final excludedRoutes =
          (tun['route-exclude-address'] as YamlList).cast<String>();

      expect(tun['inet6-address'], isNotEmpty);
      expect(dns['ipv6'], isFalse);
      expect(dns.containsKey('fake-ip-range6'), isFalse);
      expect(excludedRoutes, isNot(anyElement(contains(':'))));
      expect(rules.first, 'IP-CIDR6,::/0,REJECT,no-resolve');
      expect((parsed['proxies'] as YamlList).single['server'], '2001:db8::10');
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

      expect(rules[0], 'IP-CIDR6,::/0,REJECT,no-resolve');
      final privateDirectIndex =
          rules.indexOf('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve');
      final forcedDomainIndex =
          rules.indexOf('DOMAIN-SUFFIX,blocked.example,PROXY');
      final forcedIpIndex =
          rules.indexOf('IP-CIDR,1.2.3.4/32,PROXY,no-resolve');
      final builtInProxyIndex = rules.indexOf('DOMAIN-SUFFIX,openai.com,PROXY');
      final gfwProxyIndex = rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY');
      expect(privateDirectIndex, greaterThan(0));
      expect(forcedDomainIndex, lessThan(forcedIpIndex));
      expect(forcedIpIndex, lessThan(privateDirectIndex));
      expect(forcedIpIndex, lessThan(builtInProxyIndex));
      expect(builtInProxyIndex, lessThan(gfwProxyIndex));
      expect(
        rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT'),
        greaterThan(gfwProxyIndex),
      );
      expect(
        rules.indexOf('DOMAIN-SUFFIX,cn,DIRECT'),
        greaterThan(rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT')),
      );
    });

    test('manual proxy then manual direct outrank every automatic rule', () {
      const yaml = '''
proxies:
  - name: Test Node
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: test123
''';
      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(
            forceProxySites: const ['conflict.example', 'baidu.com'],
            forceDirectSites: const ['conflict.example', 'openai.com'],
          ),
        ),
      ) as YamlMap;
      final dns = parsed['dns'] as YamlMap;
      final policy = dns['nameserver-policy'] as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();

      final proxyConflict =
          rules.indexOf('DOMAIN-SUFFIX,conflict.example,PROXY');
      final directConflict =
          rules.indexOf('DOMAIN-SUFFIX,conflict.example,DIRECT');
      final forcedDomesticProxy =
          rules.indexOf('DOMAIN-SUFFIX,baidu.com,PROXY');
      final forcedForeignDirect =
          rules.indexOf('DOMAIN-SUFFIX,openai.com,DIRECT');
      final builtInForeignProxy =
          rules.indexOf('DOMAIN-SUFFIX,openai.com,PROXY');
      final chinaDirect = rules.indexOf('RULE-SET,ssrvpn-china-domains,DIRECT');

      expect(proxyConflict, isNonNegative);
      expect(proxyConflict, lessThan(directConflict));
      expect(forcedDomesticProxy, lessThan(chinaDirect));
      expect(forcedForeignDirect, lessThan(builtInForeignProxy));
      expect(
        directConflict,
        lessThan(rules.indexOf('DOMAIN,localhost,DIRECT')),
      );
      expect(
        (policy['+.conflict.example'] as YamlList).cast<String>(),
        everyElement(contains('#PROXY')),
      );
      expect(
        (policy['+.openai.com'] as YamlList).cast<String>(),
        containsAll(AppConstants.domesticDohNameservers),
      );
    });

    test('generateConfig emits each exact rule only once', () {
      const yaml = '''
proxies:
  - name: Test Node
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: test123
''';
      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(forceProxySites: const ['openai.com']),
          extraRulesBeforeDirect: const [
            'DOMAIN-SUFFIX,openai.com,PROXY',
            'DOMAIN-SUFFIX,openai.com,PROXY',
          ],
        ),
      ) as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();

      expect(
        rules.where((rule) => rule == 'DOMAIN-SUFFIX,openai.com,PROXY'),
        hasLength(1),
      );
      expect(
        rules.indexOf('DOMAIN-SUFFIX,openai.com,PROXY'),
        lessThan(rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY')),
      );
    });

    test('generateConfig deduplicates extra groups and rejects collisions', () {
      const yaml = '''
proxies:
  - name: Test Node
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: test123
''';
      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(),
          extraSelectGroupNames: const ['SSRVPN-GEO', ' SSRVPN-GEO '],
        ),
      ) as YamlMap;
      final names = (parsed['proxy-groups'] as YamlList)
          .map((group) => (group as YamlMap)['name'])
          .cast<String>();
      expect(names.where((name) => name == 'SSRVPN-GEO'), hasLength(1));

      expect(
        () => ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(),
          extraSelectGroupNames: const ['PROXY'],
        ),
        throwsArgumentError,
      );
      expect(
        () => ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(),
          extraSelectGroupNames: const ['DIRECT'],
        ),
        throwsArgumentError,
      );
    });

    test('generateConfig rejects raw proxies using reserved runtime names', () {
      const yaml = '''
proxies:
  - name: DIRECT
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: test123
''';

      expect(
        () => ClashConfigGenerator.generateConfig(yaml, AppSettings()),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('运行时保留名称'),
          ),
        ),
      );
    });

    test('generateConfig rejects duplicate raw proxy names', () {
      const yaml = '''
proxies:
  - {name: Duplicate, type: ss, server: a.example.com, port: 443, cipher: aes-256-gcm, password: one}
  - {name: Duplicate, type: ss, server: b.example.com, port: 443, cipher: aes-256-gcm, password: two}
''';

      expect(
        () => ClashConfigGenerator.generateConfig(yaml, AppSettings()),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('节点名称重复'),
          ),
        ),
      );
    });

    test('generateConfig rejects proxy field collisions after sanitization',
        () {
      const yaml = r'''
proxies:
  - name: Collision Node
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: visible
    "pass\u0000word": hidden
''';

      expect(
        () => ClashConfigGenerator.generateConfig(yaml, AppSettings()),
        throwsFormatException,
      );
    });

    test('proxy names are canonicalized identically in nodes and groups', () {
      const yaml = r'''
proxies:
  - name: "  \u0001Canonical Node\u0002  "
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: test123
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(yaml, AppSettings()),
      ) as YamlMap;
      final emittedProxyNames = (parsed['proxies'] as YamlList)
          .map((proxy) => (proxy as YamlMap)['name'])
          .cast<String>()
          .toSet();
      final groups = (parsed['proxy-groups'] as YamlList).cast<YamlMap>();
      final groupNames =
          groups.map((group) => group['name']).cast<String>().toSet();

      expect(emittedProxyNames, {'Canonical Node'});
      for (final group in groups) {
        final members = (group['proxies'] as YamlList).cast<String>();
        expect(
          members.where((member) => !groupNames.contains(member)),
          everyElement(isIn(emittedProxyNames)),
        );
      }
    });

    test('smart mode uses layered services and a safe proxy fallback', () {
      final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(yaml, AppSettings()),
      ) as YamlMap;
      final providers = parsed['rule-providers'] as YamlMap;
      final feedbackProvider =
          providers['ssrvpn-user-feedback-rules'] as YamlMap;
      final gfwProvider = providers['ssrvpn-geosite-gfw'] as YamlMap;
      final cnProvider = providers['ssrvpn-geosite-cn'] as YamlMap;
      final aiProvider = providers['ssrvpn-ai-services'] as YamlMap;
      final foreignProvider = providers['ssrvpn-foreign-services'] as YamlMap;
      final streamingProvider =
          providers['ssrvpn-streaming-services'] as YamlMap;
      final chinaProvider = providers['ssrvpn-china-domains'] as YamlMap;
      final asnProvider = providers['ssrvpn-company-asn'] as YamlMap;
      final dns = parsed['dns'] as YamlMap;
      final policy = dns['nameserver-policy'] as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();

      expect(parsed['etag-support'], isTrue);
      for (final provider in [gfwProvider, cnProvider]) {
        expect(provider['type'], 'http');
        expect(provider['behavior'], 'domain');
        expect(provider['format'], 'mrs');
        expect(provider.containsKey('interval'), isFalse);
        expect(provider['proxy'], 'PROXY');
        expect(provider['size-limit'], 2 * 1024 * 1024);
      }
      for (final provider in [
        feedbackProvider,
        aiProvider,
        foreignProvider,
        streamingProvider,
        chinaProvider,
        asnProvider,
      ]) {
        expect(provider['type'], 'http');
        expect(provider['format'], 'yaml');
        expect(provider.containsKey('interval'), isFalse);
        expect(provider['proxy'], 'PROXY');
        expect(provider['size-limit'], 2 * 1024 * 1024);
      }
      expect(feedbackProvider['behavior'], 'domain');
      expect(aiProvider['behavior'], 'domain');
      expect(foreignProvider['behavior'], 'domain');
      expect(streamingProvider['behavior'], 'domain');
      expect(chinaProvider['behavior'], 'domain');
      expect(asnProvider['behavior'], 'ipcidr');
      expect(
        gfwProvider['url'],
        'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/'
        '200e6a86736cfab29aae7b07dc266e59f13bc13d/'
        'geo/geosite/gfw.mrs',
      );
      expect(
        cnProvider['url'],
        'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/'
        '200e6a86736cfab29aae7b07dc266e59f13bc13d/'
        'geo/geosite/cn.mrs',
      );
      expect(gfwProvider['path'], './providers/ssrvpn-geosite-gfw.mrs');
      expect(cnProvider['path'], './providers/ssrvpn-geosite-cn.mrs');
      for (final provider in [gfwProvider, cnProvider]) {
        final url = provider['url'] as String;
        expect(
          url,
          isNot(matches(RegExp(r'/(?:main|master|latest|release)(?:/|$)'))),
        );
      }
      expect(aiProvider['path'], './providers/ai_services.yaml');
      expect(
        aiProvider['url'],
        'https://raw.githubusercontent.com/Elegying/SSRVPN/main/'
        'packages/ssrvpn_shared/assets/rules/latest/ai_services.yaml',
      );
      expect(providers, isNot(contains('ssrvpn-geoip-cn')));
      final openAiProxyIndex = rules.indexOf('DOMAIN-SUFFIX,openai.com,PROXY');
      final aiProxyIndex = rules.indexOf('RULE-SET,ssrvpn-ai-services,PROXY');
      final foreignProxyIndex =
          rules.indexOf('RULE-SET,ssrvpn-foreign-services,PROXY');
      final streamingProxyIndex =
          rules.indexOf('RULE-SET,ssrvpn-streaming-services,PROXY');
      final chinaDirectIndex =
          rules.indexOf('RULE-SET,ssrvpn-china-domains,DIRECT');
      final asnDirectIndex = rules.indexOf(
        'RULE-SET,ssrvpn-company-asn,DIRECT,no-resolve',
      );
      final gfwProxyIndex = rules.indexOf('RULE-SET,ssrvpn-geosite-gfw,PROXY');
      final domainDirectIndex =
          rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT');
      final geoIpDirectIndex = rules.indexOf('GEOIP,CN,DIRECT');
      final matchIndex = rules.indexOf('MATCH,PROXY');
      expect(openAiProxyIndex, isNonNegative);
      expect(gfwProxyIndex, isNonNegative);
      expect(aiProxyIndex, isNonNegative);
      expect(foreignProxyIndex, isNonNegative);
      expect(streamingProxyIndex, isNonNegative);
      expect(chinaDirectIndex, isNonNegative);
      expect(asnDirectIndex, isNonNegative);
      expect(domainDirectIndex, isNonNegative);
      expect(geoIpDirectIndex, isNonNegative);
      expect(matchIndex, isNonNegative);
      expect(openAiProxyIndex, lessThan(gfwProxyIndex));
      expect(aiProxyIndex, lessThan(chinaDirectIndex));
      expect(foreignProxyIndex, lessThan(chinaDirectIndex));
      expect(streamingProxyIndex, lessThan(chinaDirectIndex));
      expect(chinaDirectIndex, lessThan(asnDirectIndex));
      expect(asnDirectIndex, lessThan(gfwProxyIndex));
      expect(gfwProxyIndex, lessThan(domainDirectIndex));
      expect(domainDirectIndex, lessThan(geoIpDirectIndex));
      expect(geoIpDirectIndex, lessThan(matchIndex));
      expect(
        (policy['rule-set:ssrvpn-ai-services'] as YamlList).cast<String>(),
        [
          'https://1.1.1.1/dns-query#PROXY',
          'https://8.8.8.8/dns-query#PROXY',
        ],
      );
      expect(
        (policy['rule-set:ssrvpn-china-domains'] as YamlList).cast<String>(),
        [
          'https://dns.alidns.com/dns-query',
          'https://doh.pub/dns-query',
        ],
      );
      expect(
        (policy['rule-set:ssrvpn-geosite-gfw'] as YamlList).cast<String>(),
        [
          'https://1.1.1.1/dns-query#PROXY',
          'https://8.8.8.8/dns-query#PROXY',
        ],
      );
      expect(
        (policy['rule-set:ssrvpn-geosite-cn'] as YamlList).cast<String>(),
        [
          'https://dns.alidns.com/dns-query',
          'https://doh.pub/dns-query',
        ],
      );
      expect(rules, contains('DOMAIN-SUFFIX,cn,DIRECT'));
      expect(rules, contains('DOMAIN-SUFFIX,local,DIRECT'));
      expect(rules, contains('DOMAIN-SUFFIX,snssdk.com,DIRECT'));
      expect(rules, contains('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'));
      expect(rules, isNot(anyElement(contains('ssrvpn-geoip-cn'))));
      expect(rules, isNot(contains('MATCH,DIRECT')));
      expect(rules.last, 'MATCH,PROXY');
    });

    test('verified smart rules use one local version without remote refresh',
        () {
      const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';
      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(),
          smartRuleProviderPathPrefix: './providers/bundles/1.1.0',
        ),
      ) as YamlMap;
      final providers = parsed['rule-providers'] as YamlMap;

      for (final name in AppConstants.smartRuleProviderFiles.keys) {
        final provider = providers[name] as YamlMap;
        expect(provider['type'], 'file');
        expect(
          provider['path'],
          './providers/bundles/1.1.0/'
          '${AppConstants.smartRuleProviderFiles[name]}',
        );
        expect(provider.containsKey('url'), isFalse);
        expect(provider.containsKey('proxy'), isFalse);
      }
      expect(
        (providers[AppConstants.geositeGfwRuleProviderName] as YamlMap)['type'],
        'http',
      );
    });

    test('global mode still sends all traffic through the global selector', () {
      const yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';

      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(proxyMode: ProxyMode.global),
        ),
      ) as YamlMap;
      final groups = (parsed['proxy-groups'] as YamlList).cast<YamlMap>();
      final global = groups.firstWhere((group) => group['name'] == 'GLOBAL');

      expect(parsed['mode'], 'global');
      expect((global['proxies'] as YamlList).cast<String>(), [
        'PROXY',
        'Test Node',
      ]);
    });

    test('generateConfig preserves a visible ASCII API secret exactly', () {
      final yaml = '''
proxies:
  - name: "Test Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "test123"
''';
      const apiSecret = 'a"b\\c\'d~+/_=-.';
      final settings = AppSettings(apiSecret: apiSecret);

      final config = ClashConfigGenerator.generateConfig(yaml, settings);
      final parsed = loadYaml(config) as YamlMap;

      expect(parsed['secret'], apiSecret);
    });

    test('canonical API secret is deterministic and HTTP-header safe', () {
      const unsafeSecret = 'a\tb\nc\rd 密钥';
      final canonical = RuntimeConfigNamePolicy.canonicalApiSecret(
        unsafeSecret,
      );

      expect(RuntimeConfigNamePolicy.canonicalApiSecret(''), isEmpty);
      expect(canonical, matches(RegExp(r'^ssrvpn-sha256-[0-9a-f]{64}$')));
      expect(canonical, isNotEmpty);
      expect(
        RuntimeConfigNamePolicy.canonicalApiSecret('\r\n\t'),
        matches(RegExp(r'^ssrvpn-sha256-[0-9a-f]{64}$')),
      );
      expect(
        RuntimeConfigNamePolicy.canonicalApiSecret(unsafeSecret),
        canonical,
      );
      expect(
        RuntimeConfigNamePolicy.canonicalApiSecret('$unsafeSecret!'),
        isNot(canonical),
      );
    });

    test('canonical API secret bounds inline HTTP header length', () {
      final maximumInlineSecret = 'a' * 256;
      final oversizedSecret = 'a' * 257;

      expect(
        RuntimeConfigNamePolicy.canonicalApiSecret(maximumInlineSecret),
        maximumInlineSecret,
      );
      final canonical = RuntimeConfigNamePolicy.canonicalApiSecret(
        oversizedSecret,
      );
      expect(canonical, matches(RegExp(r'^ssrvpn-sha256-[0-9a-f]{64}$')));
      expect(canonical, hasLength(78));
      expect(canonical,
          RuntimeConfigNamePolicy.canonicalApiSecret(oversizedSecret));
    });

    test('generateConfig round-trips the canonical unsafe API secret', () {
      const yaml = '''
proxies:
  - name: Test Node
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: test123
''';
      const unsafeSecret = 'header\r\nvalue\t密钥';
      final parsed = loadYaml(
        ClashConfigGenerator.generateConfig(
          yaml,
          AppSettings(apiSecret: unsafeSecret),
        ),
      ) as YamlMap;

      expect(
        parsed['secret'],
        RuntimeConfigNamePolicy.canonicalApiSecret(unsafeSecret),
      );
      expect(parsed['secret'], isNot(unsafeSecret));
    });

    test(
      'generateConfig round-trips valid whitespace in ordinary proxy fields',
      () {
        const password = 'pass\tword\nnext\rreturn';
        const authentication = 'auth\tvalue\nnext\rreturn';
        const nestedHeader = 'Bearer\ttoken\nnext\rreturn';
        const yaml = r'''
proxies:
  - name: "Whitespace Node"
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: "pass\tword\nnext\rreturn"
    auth-str: "auth\tvalue\nnext\rreturn"
    ws-opts:
      headers:
        "Authori\u0000zation": "Bearer\ttoken\nnext\rreturn"
''';

        final parsed = loadYaml(
          ClashConfigGenerator.generateConfig(yaml, AppSettings()),
        ) as YamlMap;
        final proxy = (parsed['proxies'] as YamlList).single as YamlMap;
        final wsOptions = proxy['ws-opts'] as YamlMap;
        final headers = wsOptions['headers'] as YamlMap;

        expect(proxy['password'], password);
        expect(proxy['auth-str'], authentication);
        expect(headers.keys, ['Authorization']);
        expect(headers['Authorization'], nestedHeader);
      },
    );

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
    cipher: aes-256-gcm
    password: secret
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
    cipher: aes-256-gcm
    password: secret
  - name: "Node 2"
    type: ss
    server: example2.com
    port: 443
    cipher: aes-256-gcm
    password: secret
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
