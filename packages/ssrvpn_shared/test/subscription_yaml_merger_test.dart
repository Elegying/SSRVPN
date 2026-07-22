import 'dart:collection';

import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_yaml_merger.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('SubscriptionYamlMerger', () {
    test('merges proxies, deduplicates identical nodes, and records source',
        () {
      final yamlA = '''
proxies:
  - name: Same
    type: ss
    server: a.example.com
    port: 443
''';
      final yamlB = '''
proxies:
  - name: Same
    type: ss
    server: a.example.com
    port: 443
  - name: Same
    type: ss
    server: b.example.com
    port: 8443
''';

      final merged = SubscriptionYamlMerger.mergeYamlConfigs(
        [yamlA, yamlB],
        sourceNames: ['Primary', 'Backup'],
      );

      expect(merged, contains('"name":"Same"'));
      expect(merged, isNot(contains('"Same (2)","type":"ss","server":"a')));
      expect(merged, contains('"name":"Same (2)"'));
      expect(merged, contains('"ssrvpn-subscription":"Primary"'));
      expect(merged, contains('"ssrvpn-subscription":"Backup"'));
    });

    test('extracts top-level sections with normalized proxy indentation', () {
      final yaml = '''
mixed-port: 7890
proxies:
    - name: Node
      type: ss
proxy-groups:
  - name: PROXY
''';

      expect(
        SubscriptionYamlMerger.extractSection(yaml, 'proxies'),
        '  - name: Node\n    type: ss',
      );
    });

    test('allocates duplicate names with a linear number of set probes', () {
      const proxyCount = 4000;
      final usedNames = _CountingSet<String>();
      final nextSuffixByBase = <String, int>{};

      final names = <String>[];
      for (var i = 0; i < proxyCount; i++) {
        names.add(
          SubscriptionYamlMerger.uniqueProxyName(
            'Same',
            usedNames,
            nextSuffixByBase: nextSuffixByBase,
          ),
        );
      }

      expect(names.take(3), ['Same', 'Same (2)', 'Same (3)']);
      expect(names.last, 'Same ($proxyCount)');
      expect(usedNames.addCalls, lessThanOrEqualTo(proxyCount + 1));
    });

    test('stably merges thousands of different nodes with the same name', () {
      const proxyCount = 3000;
      final yaml = StringBuffer('proxies:\n');
      for (var i = 0; i < proxyCount; i++) {
        yaml
          ..writeln('  - name: Same')
          ..writeln('    type: ss')
          ..writeln('    server: node-$i.example.com')
          ..writeln('    port: 443');
      }

      final stopwatch = Stopwatch()..start();
      final merged = SubscriptionYamlMerger.mergeYamlConfigs([
        yaml.toString(),
      ]);
      stopwatch.stop();

      expect(merged.split('\n').where((line) => line.startsWith('  - ')),
          hasLength(proxyCount));
      expect(merged, contains('"name":"Same"'));
      expect(merged, contains('"name":"Same (2)"'));
      expect(merged, contains('"name":"Same ($proxyCount)"'));
      // This is deliberately generous: the deterministic probe-count test
      // proves complexity, while this only guards against an input freeze.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
    });

    test('reserves every runtime group and built-in policy name', () {
      const yaml = '''
proxies:
  - {name: PROXY, type: trojan, server: proxy.example.com, port: 443, password: secret}
  - {name: GLOBAL, type: trojan, server: global.example.com, port: 443, password: secret}
  - {name: 自动选择, type: trojan, server: auto.example.com, port: 443, password: secret}
  - {name: 故障转移, type: trojan, server: fallback.example.com, port: 443, password: secret}
  - {name: SSRVPN-GEO, type: trojan, server: geo.example.com, port: 443, password: secret}
  - {name: DIRECT, type: trojan, server: direct.example.com, port: 443, password: secret}
  - {name: REJECT, type: trojan, server: reject.example.com, port: 443, password: secret}
  - {name: REJECT-DROP, type: trojan, server: reject-drop.example.com, port: 443, password: secret}
  - {name: PASS, type: trojan, server: pass.example.com, port: 443, password: secret}
  - {name: COMPATIBLE, type: trojan, server: compatible.example.com, port: 443, password: secret}
''';

      final merged = SubscriptionYamlMerger.mergeYamlConfigs([yaml]);
      expect(ClashConfigGenerator.extractProxyNames(merged), [
        'PROXY (2)',
        'GLOBAL (2)',
        '自动选择 (2)',
        '故障转移 (2)',
        'SSRVPN-GEO (2)',
        'DIRECT (2)',
        'REJECT (2)',
        'REJECT-DROP (2)',
        'PASS (2)',
        'COMPATIBLE (2)',
      ]);

      final generated = loadYaml(
        ClashConfigGenerator.generateConfig(
          merged,
          AppSettings(),
          includeFallbackGroup: true,
          extraSelectGroupNames: const ['SSRVPN-GEO'],
        ),
      ) as YamlMap;
      final proxyNames = (generated['proxies'] as YamlList)
          .map((proxy) => (proxy as YamlMap)['name'])
          .cast<String>()
          .toSet();
      final groupNames = (generated['proxy-groups'] as YamlList)
          .map((group) => (group as YamlMap)['name'])
          .cast<String>()
          .toList();

      expect(groupNames.toSet(), hasLength(groupNames.length));
      expect(proxyNames.intersection(groupNames.toSet()), isEmpty);
    });

    test('canonicalizes control characters before collision allocation', () {
      const yaml = r'''
proxies:
  - {name: Node, type: trojan, server: first.example.com, port: 443, password: secret}
  - {name: "\u0001Node", type: trojan, server: second.example.com, port: 443, password: secret}
  - {name: "P\u0001ROXY", type: trojan, server: reserved.example.com, port: 443, password: secret}
  - {name: Line, type: trojan, server: line.example.com, port: 443, password: secret}
  - {name: "L\tine", type: trojan, server: tab.example.com, port: 443, password: secret}
  - {name: "L\nine", type: trojan, server: newline.example.com, port: 443, password: secret}
  - {name: "L\rine", type: trojan, server: carriage-return.example.com, port: 443, password: secret}
''';

      final merged = SubscriptionYamlMerger.mergeYamlConfigs([yaml]);

      expect(
        ClashConfigGenerator.extractProxyNames(merged),
        [
          'Node',
          'Node (2)',
          'PROXY (2)',
          'Line',
          'Line (2)',
          'Line (3)',
          'Line (4)',
        ],
      );
      expect(
        () => ClashConfigGenerator.generateConfig(merged, AppSettings()),
        returnsNormally,
      );
      expect(
        () => ClashConfigGenerator.generateConfig(
          merged,
          AppSettings(),
          extraSelectGroupNames: const ['P\u0001ROXY'],
        ),
        throwsArgumentError,
      );
    });

    test('canonicalizes source names before stable suffix allocation', () {
      const yamlA = '''
proxies:
  - {name: One, type: ss, server: one.example.com, port: 443, cipher: aes-128-gcm, password: secret}
''';
      const yamlB = '''
proxies:
  - {name: Two, type: ss, server: two.example.com, port: 443, cipher: aes-128-gcm, password: secret}
''';

      final merged = SubscriptionYamlMerger.mergeYamlConfigs(
        [yamlA, yamlB],
        sourceNames: const ['Primary', '\u0001Primary'],
      );

      expect(merged, contains('"ssrvpn-subscription":"Primary"'));
      expect(merged, contains('"ssrvpn-subscription":"Primary (2)"'));
    });

    test('rejects a merged subscription with too many proxy items', () {
      final yaml = StringBuffer('proxies:\n');
      for (var i = 0; i <= SubscriptionYamlMerger.maxMergedProxyNodes; i++) {
        yaml.writeln('  - not-a-valid-proxy-$i');
      }

      expect(
        () => SubscriptionYamlMerger.mergeYamlConfigs([yaml.toString()]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('节点数量超过上限'),
          ),
        ),
      );
    });

    test('rejects an oversized proxy field before emitting output', () {
      final oversizedName =
          'n' * (SubscriptionYamlMerger.maxProxyFieldLength + 1);
      final yaml = '''
proxies:
  - name: $oversizedName
    type: ss
    server: example.com
    port: 443
''';

      expect(
        () => SubscriptionYamlMerger.mergeYamlConfigs([yaml]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('字段长度超过上限'),
          ),
        ),
      );
    });

    test('rejects total merge input beyond the fetcher size envelope', () {
      final oversizedInput =
          'x' * (SubscriptionYamlMerger.maxMergedInputBytes + 1);

      expect(
        () => SubscriptionYamlMerger.mergeYamlConfigs([oversizedInput]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('合并输入大小超过上限'),
          ),
        ),
      );
    });
  });
}

class _CountingSet<E> extends SetBase<E> {
  final Set<E> _values = <E>{};
  int addCalls = 0;

  @override
  bool add(E value) {
    addCalls++;
    return _values.add(value);
  }

  @override
  bool contains(Object? element) => _values.contains(element);

  @override
  Iterator<E> get iterator => _values.iterator;

  @override
  int get length => _values.length;

  @override
  E? lookup(Object? element) => _values.lookup(element);

  @override
  bool remove(Object? value) => _values.remove(value);

  @override
  Set<E> toSet() => _values.toSet();
}
