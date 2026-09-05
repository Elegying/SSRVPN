import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/settings_service.dart';

const _oldYaml =
    'proxies:\n  - {name: Original, type: socks5, server: old.invalid, port: 443}\n';
const _stagedYaml =
    'proxies:\n  - {name: Edited, type: socks5, server: new.invalid, port: 443}\n';
const _marker = '.portable-migration-v1';

void main() {
  late Directory source;
  late Directory target;
  File sourceFile(String name) => File('${source.path}/$name');
  File targetFile(String name) => File('${target.path}/$name');
  final metadata = jsonEncode([
    Subscription(
            id: 'a', name: 'Original', url: 'socks5://old.invalid:443#Original')
        .toJson(),
  ]);
  Future<void> stage(
      {int version = 1,
      bool empty = false,
      bool otherSelection = false}) async {
    await sourceFile('subscriptions.json').writeAsString('[]');
    await sourceFile('subscription_cache.yaml').writeAsString(_stagedYaml);
    await sourceFile('settings.json').writeAsString(jsonEncode(AppSettings(
      lastSelectedNodeName: otherSelection
          ? 'Other'
          : version == 2
              ? 'Edited'
              : 'Original',
      lastSelectedNodeRenameId: version == 2 && !otherSelection ? 'edit-1' : '',
      proxyPort: 8890,
    ).toJson()
      ..remove('apiSecret')));
    await sourceFile(SubscriptionUndoRecord.fileName).writeAsString(jsonEncode({
      'version': version,
      'files': {
        'subscriptions.json': empty ? null : metadata,
        'subscription_cache.yaml': empty ? null : _oldYaml
      },
      if (version == 2)
        'preference':
            const NodePreferenceRename('Original', 'Edited', 'edit-1').toJson(),
    }));
  }

  Future<void> migrate() =>
      SettingsService.migrateInstalledDataForTesting(source.path, target.path);
  setUp(() async {
    source = await Directory.systemTemp.createTemp('ssrvpn-installed-undo-');
    target = await Directory.systemTemp.createTemp('ssrvpn-fallback-undo-');
  });
  tearDown(() async {
    await source.delete(recursive: true);
    await target.delete(recursive: true);
  });

  for (final version in [1, 2]) {
    test(
        'v$version migration recovers committed files without writing the source',
        () async {
      await stage(version: version);
      final unchanged = <String, String>{};
      await for (final file in source.list()) {
        if (file is File) unchanged[file.path] = await file.readAsString();
      }
      await migrate();
      expect(await targetFile('subscriptions.json').readAsString(), metadata);
      expect(
          await targetFile('subscription_cache.yaml').readAsString(), _oldYaml);
      expect(
          await targetFile(SubscriptionUndoRecord.fileName).exists(), isFalse);
      expect((await targetFile(_marker).readAsString()).trim(), '1');
      for (final entry in unchanged.entries) {
        expect(await File(entry.key).readAsString(), entry.value);
      }
      final settings = await SettingsService.createForTesting(
        dataDir: target.path,
        settingsPath: targetFile('settings.json').path,
        readApiSecret: () async => 'synthetic-secret',
        writeApiSecret: (_) async {},
      );
      addTearDown(settings.dispose);
      final subscription = _Service();
      addTearDown(subscription.dispose);
      await subscription.init(target.path, preferences: settings);
      expect(subscription.subscriptions.single.id, 'a');
      expect(subscription.allNodes.single.name, 'Original');
      expect(settings.settings.lastSelectedNodeName, 'Original');
      expect(settings.settings.proxyPort, 8890);
    });
  }

  test('uncommitted initial import is absent after migration', () async {
    await stage(empty: true);
    await migrate();
    expect(await targetFile('subscriptions.json').exists(), isFalse);
    expect(await targetFile('subscription_cache.yaml').exists(), isFalse);
    expect(await targetFile(_marker).exists(), isTrue);
  });

  test('a later independent selection is preserved during v2 migration',
      () async {
    await stage(version: 2, otherSelection: true);
    await migrate();
    final settings =
        jsonDecode(await targetFile('settings.json').readAsString());
    expect(settings['lastSelectedNodeName'], 'Other');
    expect(settings['lastSelectedNodeRenameId'], isEmpty);
  });

  test('interrupted migration resumes from the same committed snapshot',
      () async {
    await stage(version: 2);
    final blocked = Directory(targetFile('subscription_cache.yaml').path);
    await blocked.create();
    await expectLater(migrate(), throwsA(isA<FileSystemException>()));
    expect(await targetFile(_marker).exists(), isFalse);
    expect(await targetFile('subscriptions.json').readAsString(), metadata);
    await blocked.delete();
    await migrate();
    expect(
        await targetFile('subscription_cache.yaml').readAsString(), _oldYaml);
    expect(await targetFile(_marker).exists(), isTrue);
  });

  for (final empty in [false, true]) {
    test('conflicting fallback cache is preserved, old absence=$empty',
        () async {
      await stage(empty: empty);
      await targetFile('subscription_cache.yaml')
          .writeAsString('keep-existing');
      await expectLater(migrate(), throwsStateError);
      expect(await targetFile('subscription_cache.yaml').readAsString(),
          'keep-existing');
      expect(await targetFile(_marker).exists(), isFalse);
    });
  }

  test(
      'an interrupted temporary copy is not treated as committed fallback data',
      () async {
    await stage(version: 2);
    await targetFile('subscription_cache.yaml.migration.incomplete')
        .writeAsString('partial');
    await migrate();
    expect(
        await targetFile('subscription_cache.yaml').readAsString(), _oldYaml);
    expect(await targetFile(_marker).exists(), isTrue);
  });

  test('malformed undo record fails before any migration copy', () async {
    await stage();
    await sourceFile(SubscriptionUndoRecord.fileName).writeAsString('{broken');
    await expectLater(migrate(), throwsFormatException);
    expect(await target.list().toList(), isEmpty);
  });

  test('fallback recovery is not overwritten by an unfinished source migration',
      () async {
    await stage();
    await targetFile(SubscriptionUndoRecord.fileName)
        .writeAsString('keep-own-recovery');
    await expectLater(migrate(), throwsStateError);
    expect(await targetFile(SubscriptionUndoRecord.fileName).readAsString(),
        'keep-own-recovery');
    expect(await targetFile(_marker).exists(), isFalse);
  });
}

class _Service extends SubscriptionServiceBase {
  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      throw StateError('unexpected network request');
}
