import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/smart_rule_snapshot_retention.dart';

void main() {
  late Directory root;
  File provider(int version) =>
      File('${root.path}/providers/bundles/$version.0.0/a.yaml');
  Future<int> prune({List<String> paths = const []}) =>
      SmartRuleSnapshotRetention.prune(root.path,
          protectedVersions: {'1.0.0', '6.0.0'},
          protectedConfigPaths: paths,
          fileNames: {'a.yaml'});
  Future<void> config(String path, List<int> versions) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(jsonEncode({
      'rule-providers': {
        for (final v in versions)
          'p$v': {'path': './providers/bundles/$v.0.0/a.yaml'}
      },
      'proxies': [
        {'password': 'opaque-node-credential'}
      ]
    }));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rule-retention-');
    for (var v = 1; v <= 6; v++) {
      await provider(v).parent.create(recursive: true);
      await provider(v).writeAsString('payload: [v$v]');
    }
  });
  tearDown(() async => root.delete(recursive: true));

  test('retains confirmed, selected and two newest unreferenced versions',
      () async {
    expect(await prune(), 2);
    for (final v in [1, 4, 5, 6]) {
      expect(await provider(v).readAsString(), 'payload: [v$v]');
    }
    for (final v in [2, 3]) {
      expect(await provider(v).parent.exists(), isFalse);
    }
  });

  test(
      'nested configs, mixed providers and native idle references are retained',
      () async {
    final runtime = '${root.path}/nested/config.yaml';
    final native = '${root.path}/tile-snapshot.data';
    await config(runtime, [2, 3]);
    await config(native, [4]);
    final original = await File(native).readAsBytes();
    expect(await prune(paths: [native]), 0);
    expect(await File(native).readAsBytes(), original);
    for (var v = 1; v <= 6; v++) {
      expect(await provider(v).exists(), isTrue);
    }
  });

  test('uppercase config extensions still protect referenced snapshots',
      () async {
    await config('${root.path}/saved.YAML', [2]);
    expect(await prune(), 1);
    expect(await provider(2).exists(), isTrue);
  });

  test('subscription list beside runtime config does not disable collection',
      () async {
    final subscriptions = File('${root.path}/subscriptions.json');
    const saved = '[{"id":"saved-subscription","name":"用户订阅"}]';
    await subscriptions.writeAsString(saved);
    await config('${root.path}/config.yaml', [2]);
    expect(await prune(), 1);
    expect(await subscriptions.readAsString(), saved);
    expect(await provider(2).exists(), isTrue);
    expect(await provider(3).exists(), isFalse);
  });

  test('noncanonical bundle casing defers deletion on every platform',
      () async {
    final path = '${root.path}/config.yaml';
    await config(path, [2]);
    final file = File(path);
    await file.writeAsString(
        (await file.readAsString()).replaceAll('/bundles/', '/BUNDLES/'));
    await expectLater(prune(), throwsA(isA<FormatException>()));
    for (var v = 1; v <= 6; v++) {
      expect(await provider(v).exists(), isTrue);
    }
  });

  test('semantic sorting preserves 10 before 6 rather than string order',
      () async {
    await provider(10).parent.create(recursive: true);
    await provider(10).writeAsString('ten');
    expect(await prune(), 3);
    expect(await provider(10).readAsString(), 'ten');
    expect(await provider(5).exists(), isTrue);
    expect(await provider(4).parent.exists(), isFalse);
  });

  test('escaped JSON references are protected without rewriting config',
      () async {
    final path = '${root.path}/config.yaml';
    await config(path, [2]);
    final file = File(path);
    await file.writeAsString(
        (await file.readAsString()).replaceAll('2.0.0', r'\u0032.0.0'));
    final original = await file.readAsBytes();
    expect(await prune(), 1);
    expect(await provider(2).exists(), isTrue);
    expect(await file.readAsBytes(), original);
  });

  test('credential text is never treated as a provider reference', () async {
    final path = '${root.path}/config.yaml';
    final file = File(path);
    await file.writeAsString(jsonEncode({
      'proxies': [
        {'password': './providers/bundles/2.0.0/a.yaml'}
      ]
    }));
    final original = await file.readAsBytes();
    expect(await prune(), 2);
    expect(await provider(2).exists(), isFalse);
    expect(await file.readAsBytes(), original);
  });

  for (final invalid in ['missing', 'malformed', 'traversal', 'non-map']) {
    test('$invalid reference defers every deletion', () async {
      final path = '${root.path}/config.yaml';
      if (invalid == 'malformed') await File(path).writeAsString('{broken');
      if (invalid == 'non-map') await File(path).writeAsString('[]');
      if (invalid == 'traversal') {
        await File(path).writeAsString(
            'rule-providers: {p: {path: ./providers/bundles/../a.yaml}}');
      }
      await expectLater(
          prune(paths: [path]),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>(),
              isA<FileSystemException>())));
      for (var v = 1; v <= 6; v++) {
        expect(await provider(v).readAsString(), 'payload: [v$v]');
      }
    });
  }

  test('unknown bundle children are preserved', () async {
    final sentinel = File('${provider(2).parent.path}/customer.txt');
    await sentinel.writeAsString('must remain');
    expect(await prune(), 1);
    expect(await sentinel.readAsString(), 'must remain');
    expect(await provider(2).exists(), isTrue);
  });

  test('unknown newer directories do not consume the fallback reserve',
      () async {
    final marker = File('${root.path}/providers/bundles/100.0.0/customer.txt');
    await marker.parent.create(recursive: true);
    await marker.writeAsString('unowned');
    expect(await prune(), 2);
    expect(await provider(4).readAsString(), 'payload: [v4]');
    expect(await provider(5).readAsString(), 'payload: [v5]');
    expect(await marker.readAsString(), 'unowned');
  });

  test('oversized reference input aborts before deleting any version',
      () async {
    final file =
        File('${root.path}/oversized.yaml').openSync(mode: FileMode.write);
    try {
      file.truncateSync(33 * 1024 * 1024);
    } finally {
      file.closeSync();
    }
    await expectLater(prune(), throwsA(isA<FormatException>()));
    expect(await provider(2).exists(), isTrue);
    expect(await provider(3).exists(), isTrue);
  });

  test('directory links never delete external data', () async {
    final external = await Directory.systemTemp.createTemp('rule-external-');
    addTearDown(() => external.delete(recursive: true));
    final sentinel = File('${external.path}/a.yaml');
    await sentinel.writeAsString('external');
    await provider(2).parent.delete(recursive: true);
    await Link(provider(2).parent.path).create(external.path);
    expect(await prune(), 1);
    expect(await sentinel.readAsString(), 'external');
    expect(await Link(provider(2).parent.path).exists(), isTrue);
  }, skip: Platform.isWindows); // Unprivileged Windows CI cannot create links.

  test('config links make references unknown and defer collection', () async {
    final target = '${root.path}/snapshot.data';
    await config(target, [2]);
    await Link('${root.path}/config.yaml').create(target);
    await expectLater(prune(), throwsA(isA<Exception>()));
    expect(await provider(2).exists(), isTrue);
    expect(await provider(3).exists(), isTrue);
  }, skip: Platform.isWindows);
}
