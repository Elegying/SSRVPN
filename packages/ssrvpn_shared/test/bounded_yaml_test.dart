import 'package:ssrvpn_shared/utils/bounded_yaml.dart';
import 'package:test/test.dart';

void main() {
  group('BoundedYaml', () {
    test('loads ordinary subscription YAML', () {
      final parsed = BoundedYaml.load('''
proxies:
  - name: Node A
    type: ss
    server: example.com
    port: 443
''');

      expect(parsed['proxies'], hasLength(1));
    });

    test('rejects block nesting beyond the configured depth', () {
      final yaml = StringBuffer('root:\n');
      for (var depth = 0; depth <= BoundedYaml.maxNestingDepth; depth++) {
        yaml.writeln('${'  ' * (depth + 1)}level$depth:');
      }

      expect(
        () => BoundedYaml.load(yaml.toString()),
        throwsA(
          isA<YamlResourceLimitException>().having(
            (error) => error.message,
            'message',
            contains('嵌套'),
          ),
        ),
      );
    });

    test('rejects flow nesting beyond the configured depth', () {
      final yaml = 'value: ${'[' * (BoundedYaml.maxNestingDepth + 1)}'
          '0${']' * (BoundedYaml.maxNestingDepth + 1)}';

      expect(
        () => BoundedYaml.load(yaml),
        throwsA(isA<YamlResourceLimitException>()),
      );
    });

    test('rejects excessive alias references before loading', () {
      final yaml = StringBuffer('base: &base {name: node}\nitems:\n');
      for (var index = 0; index <= BoundedYaml.maxAliasReferences; index++) {
        yaml.writeln('  - *base');
      }

      expect(
        () => BoundedYaml.load(yaml.toString()),
        throwsA(
          isA<YamlResourceLimitException>().having(
            (error) => error.message,
            'message',
            contains('别名'),
          ),
        ),
      );
    });

    test('rejects excessive block collection items before loading', () {
      final yaml = StringBuffer('proxies:\n');
      for (var index = 0; index <= BoundedYaml.maxCollectionItems; index++) {
        yaml.writeln('  - {}');
      }

      expect(
        () => BoundedYaml.validate(yaml.toString()),
        throwsA(
          isA<YamlResourceLimitException>().having(
            (error) => error.message,
            'message',
            contains('集合元素'),
          ),
        ),
      );
    });

    test('rejects excessive flow collection items before loading', () {
      final yaml = 'proxies: ['
          '${List.filled(BoundedYaml.maxCollectionItems + 1, '{}').join(',')}]';

      expect(
        () => BoundedYaml.validate(yaml),
        throwsA(isA<YamlResourceLimitException>()),
      );
    });

    test('does not count quoted or block-scalar syntax as structure', () {
      final bracketText = '[' * (BoundedYaml.maxNestingDepth + 5);
      final aliasText = '*alias ' * (BoundedYaml.maxAliasReferences + 5);
      final parsed = BoundedYaml.load('''
quoted: "$bracketText"
literal: |
  $aliasText
  ${'  ' * (BoundedYaml.maxNestingDepth + 5)}still text
''');

      expect(parsed['quoted'], bracketText);
      expect(parsed['literal'], contains('*alias'));
    });
  });
}
