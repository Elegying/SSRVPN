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

    test('rejects alias expansion beyond the collection budget', () {
      final yaml = StringBuffer('value0: &value0 [zero]\n');
      for (var i = 1; i <= 18; i++) {
        yaml.writeln('value$i: &value$i [*value${i - 1}, *value${i - 1}]');
      }
      expect(() => BoundedYaml.load(yaml.toString()),
          throwsA(isA<YamlResourceLimitException>()));
    });

    test('rejects alias expansion beyond the depth budget', () {
      final yaml = StringBuffer('value0: &value0 []\n');
      for (var i = 1; i <= BoundedYaml.maxNestingDepth; i++) {
        yaml.writeln('value$i: &value$i [*value${i - 1}]');
      }
      expect(() => BoundedYaml.load(yaml.toString()),
          throwsA(isA<YamlResourceLimitException>()));
    });

    test('rejects repeated scalar aliases beyond the UTF-8 byte budget', () {
      final yaml = 'value: &value "${'汉' * 30000}"\n'
          'copies: [${List.filled(240, '*value').join(',')}]';
      expect(() => BoundedYaml.load(yaml),
          throwsA(isA<YamlResourceLimitException>()));
    });

    test('plain scalar quotes cannot hide excessive block nesting', () {
      for (final quote in ["'", '"']) {
        final yaml = StringBuffer('name: node${quote}label\nroot:\n');
        for (var depth = 0; depth <= BoundedYaml.maxNestingDepth; depth++) {
          yaml.writeln('${'  ' * (depth + 1)}level$depth:');
        }
        expect(() => BoundedYaml.validate(yaml.toString()),
            throwsA(isA<YamlResourceLimitException>()));
      }
    });

    test('plain scalar quotes cannot hide excessive alias references', () {
      final yaml = StringBuffer("name: O'Reilly\nbase: &base {}\nitems:\n");
      for (var index = 0; index <= BoundedYaml.maxAliasReferences; index++) {
        yaml.writeln('  - *base');
      }
      expect(() => BoundedYaml.validate(yaml.toString()),
          throwsA(isA<YamlResourceLimitException>()));
    });

    test('ordinary quotes within plain scalars remain valid', () {
      final parsed = BoundedYaml.load('name: O\'Reilly\nlabel: node"label\n');
      expect(parsed['name'], "O'Reilly");
      expect(parsed['label'], 'node"label');
    });

    test('plain punctuation and continuation cannot start quoted scalars', () {
      for (final label in [
        "O'Reilly",
        'one, "label',
        'one- "label',
        'plain\n  "unfinished',
        'plain\n  # comment\n  "unfinished'
      ]) {
        final yaml = StringBuffer('name: $label\nbase: &base {}\nitems:\n');
        for (var index = 0; index <= BoundedYaml.maxAliasReferences; index++) {
          yaml.writeln('  - *base');
        }
        expect(() => BoundedYaml.validate(yaml.toString()),
            throwsA(isA<YamlResourceLimitException>()));
      }
    });

    test('a bare sequence entry does not hide nested collections', () {
      for (final prefix in ['items:\n  -\n', '---\n']) {
        final yaml = StringBuffer(prefix);
        for (var depth = 0; depth <= BoundedYaml.maxNestingDepth; depth++) {
          yaml.writeln('${'  ' * (depth + 2)}level$depth:');
        }
        expect(() => BoundedYaml.validate(yaml.toString()),
            throwsA(isA<YamlResourceLimitException>()));
      }
    });

    test('tags, anchors and multiline quoted strings remain scalar text', () {
      final brackets = '[' * (BoundedYaml.maxNestingDepth + 5);
      final parsed = BoundedYaml.load('''
name: &name !!str "$brackets
  continued"
copy: *name
values: ["$brackets", '$brackets']
''');
      expect(parsed['name'], contains(brackets));
      expect(parsed['copy'], parsed['name']);
      expect(parsed['values'], [brackets, brackets]);
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
