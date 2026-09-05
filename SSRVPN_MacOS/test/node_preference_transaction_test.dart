import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

const _yaml = 'proxies:\n'
    '  - {name: Decoy, type: socks5, server: decoy.invalid, port: 443}\n'
    '  - {name: Original, type: socks5, server: original.invalid, port: 443}\n';

void main() {
  late Directory directory;
  late SettingsService settings;
  late _Service subscription;
  Future<void> Function(AppSettings)? afterSettingsWrite;
  var failRecovery = false;
  File file(String name) => File('${directory.path}/$name');
  Future<void> saveSettings(AppSettings value) async {
    if (failRecovery && value.lastSelectedNodeName == 'Original') {
      throw const FileSystemException('synthetic recovery failure');
    }
    await file('settings.json').writeAsString(
        jsonEncode(value.toJson()..remove('apiSecret')),
        flush: true);
    await afterSettingsWrite?.call(value);
  }

  Future<void> rename({String name = 'Edited\tNode'}) =>
      subscription.updateNode(
        'Original',
        {...subscription.allNodes.last.extra, 'name': name},
        preferences: settings,
      );
  Future<void> copySnapshot(Directory target) async {
    await for (final entry in directory.list()) {
      if (entry is File) {
        await entry.copy('${target.path}/${entry.uri.pathSegments.last}');
      }
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('ssrvpn-joint-edit-');
    afterSettingsWrite = null;
    failRecovery = false;
    final initial = AppSettings(lastSelectedNodeName: 'Original');
    await saveSettings(initial);
    settings = await SettingsService.createForTesting(
      settings: initial,
      dataDir: directory.path,
      settingsPath: file('settings.json').path,
      readApiSecret: () async => 'synthetic-secret',
      writeApiSecret: (_) async {},
      writeSettings: saveSettings,
    );
    subscription = _Service();
    await subscription.init(directory.path, preferences: settings);
    await subscription.setRawYaml(_yaml);
  });
  tearDown(() async {
    settings.dispose();
    subscription.dispose();
    await directory.delete(recursive: true);
  });

  for (final checkpoint in ['journal', 'preference', 'yaml', 'commit']) {
    test('restart recovers both stores at $checkpoint', () async {
      final crashed =
          await Directory.systemTemp.createTemp('ssrvpn-joint-crash-');
      addTearDown(() => crashed.delete(recursive: true));
      var captured = false;
      Future<void> capture() async {
        if (captured) return;
        captured = true;
        if (checkpoint != 'commit') {
          expect(settings.settings.lastSelectedNodeName, 'Original');
          expect(subscription.allNodes.last.name, 'Original');
        }
        await copySnapshot(crashed);
      }

      subscription.afterWrite = (written) async {
        if ((checkpoint == 'journal' &&
                written.path.endsWith(SubscriptionUndoRecord.fileName)) ||
            (checkpoint == 'yaml' &&
                written.path.endsWith('subscription_cache.yaml'))) {
          await capture();
        }
      };
      afterSettingsWrite = (_) async {
        if (checkpoint == 'preference') await capture();
      };
      var published = 0;
      void verifyPublication() {
        expect(settings.settings.lastSelectedNodeName, 'EditedNode');
        expect(subscription.allNodes.last.name, 'EditedNode');
        expect(file(SubscriptionUndoRecord.fileName).existsSync(), isFalse);
        published++;
      }

      settings.addListener(verifyPublication);
      subscription.addListener(verifyPublication);
      await rename();
      expect(published, 2);
      if (checkpoint == 'commit') await capture();
      expect(captured, isTrue);
      final recoveredSettings = await SettingsService.createForTesting(
        dataDir: crashed.path,
        settingsPath: '${crashed.path}/settings.json',
        readApiSecret: () async => 'synthetic-secret',
        writeApiSecret: (_) async {},
      );
      addTearDown(recoveredSettings.dispose);
      final recovered = _Service();
      addTearDown(recovered.dispose);
      await recovered.init(crashed.path, preferences: recoveredSettings);
      final expected = checkpoint == 'commit' ? 'EditedNode' : 'Original';
      expect(recoveredSettings.settings.lastSelectedNodeName, expected);
      expect(recovered.allNodes.last.name, expected);
      expect(
          HomeNodeController.resolveDefaultNodeFrom(
                  recovered.allNodes, expected)!
              .server,
          'original.invalid');
      expect(
          await File('${crashed.path}/${SubscriptionUndoRecord.fileName}')
              .exists(),
          isFalse);
    });
  }

  test('settings queue waits for joint commit before an independent selection',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    afterSettingsWrite = (_) async {
      afterSettingsWrite = null;
      entered.complete();
      await release.future;
    };
    final edit = rename();
    await entered.future;
    final select = settings.updateLastSelectedNodeName('Decoy');
    expect(settings.settings.lastSelectedNodeName, 'Original');
    expect(subscription.allNodes.last.name, 'Original');
    release.complete();
    await Future.wait([edit, select]);
    expect(subscription.allNodes.last.name, 'EditedNode');
    expect(settings.settings.lastSelectedNodeName, 'Decoy');
    expect(settings.settings.lastSelectedNodeRenameId, isEmpty);
    expect(
        jsonDecode(
            await file('settings.json').readAsString())['lastSelectedNodeName'],
        'Decoy');
  });

  for (final checkpoint in ['preference', 'yaml']) {
    test(
        'write reports failure after replacing $checkpoint and still rolls back',
        () async {
      Future<void> failOnce() async {
        afterSettingsWrite = null;
        subscription.afterWrite = null;
        throw const FileSystemException(
            'synthetic post-write durability failure');
      }

      if (checkpoint == 'preference') {
        afterSettingsWrite = (_) => failOnce();
      } else {
        subscription.afterWrite = (written) async {
          if (written.path.endsWith('subscription_cache.yaml')) {
            await failOnce();
          }
        };
      }
      await expectLater(rename(), throwsA(isA<FileSystemException>()));
      expect(subscription.rawYaml, _yaml);
      expect(settings.settings.lastSelectedNodeName, 'Original');
      expect(
          jsonDecode(await file('settings.json').readAsString())[
              'lastSelectedNodeName'],
          'Original');
      expect(await file('subscription_cache.yaml').readAsString(), _yaml);
      expect(await file(SubscriptionUndoRecord.fileName).exists(), isFalse);
    });
  }

  test(
      'failed recovery retains its record and cannot overwrite a later selection',
      () async {
    subscription.afterWrite = (written) async {
      if (!written.path.endsWith('subscription_cache.yaml')) return;
      subscription.afterWrite = null;
      failRecovery = true;
      throw const FileSystemException('synthetic cache failure');
    };
    await expectLater(rename(), throwsA(isA<StateError>()));
    expect(await file(SubscriptionUndoRecord.fileName).exists(), isTrue);
    await expectLater(
        subscription.setRawYaml(_yaml), throwsA(isA<FileSystemException>()));
    expect(await file(SubscriptionUndoRecord.fileName).exists(), isTrue);
    expect(subscription.rawYaml, _yaml);
    await settings.updateLastSelectedNodeName('Decoy');
    failRecovery = false;
    await subscription.setRawYaml(_yaml);
    expect(settings.settings.lastSelectedNodeName, 'Decoy');
    expect(await file(SubscriptionUndoRecord.fileName).exists(), isFalse);
    expect(
        jsonDecode(
            await file('settings.json').readAsString())['lastSelectedNodeName'],
        'Decoy');
  });

  test('startup without the required preference store keeps recovery intact',
      () async {
    final crashed =
        await Directory.systemTemp.createTemp('ssrvpn-missing-store-');
    addTearDown(() => crashed.delete(recursive: true));
    afterSettingsWrite = (_) => copySnapshot(crashed);
    await rename();
    final recovered = _Service();
    addTearDown(recovered.dispose);
    await expectLater(recovered.init(crashed.path), throwsStateError);
    expect(
        await File('${crashed.path}/${SubscriptionUndoRecord.fileName}')
            .exists(),
        isTrue);
    expect(await File('${crashed.path}/subscription_cache.yaml').readAsString(),
        _yaml);
  });

  test('an unselected node does not create a preference recovery dependency',
      () async {
    await settings.updateLastSelectedNodeName('Decoy');
    subscription.afterWrite = (written) async {
      if (written.path.endsWith(SubscriptionUndoRecord.fileName)) {
        final record = await SubscriptionUndoRecord.read(written);
        expect(record!.preference, isNull);
      }
    };
    afterSettingsWrite =
        (_) async => fail('unselected edit must not write preferences');
    await rename();
    expect(settings.settings.lastSelectedNodeName, 'Decoy');
  });
}

class _Service extends SubscriptionServiceBase {
  Future<void> Function(File)? afterWrite;
  @override
  Future<void> writeStringAtomically(File file, String content) async {
    await super.writeStringAtomically(file, content);
    await afterWrite?.call(file);
  }

  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      throw StateError('unexpected network request');
}
