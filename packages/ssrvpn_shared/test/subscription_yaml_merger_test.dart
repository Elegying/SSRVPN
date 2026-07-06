import 'package:ssrvpn_shared/services/subscription_yaml_merger.dart';
import 'package:test/test.dart';

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
  });
}
