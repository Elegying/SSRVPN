import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  late Directory tempDirectory;
  late String settingsPath;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDirectory = await Directory.systemTemp.createTemp('ssrvpn-settings-');
    settingsPath =
        '${tempDirectory.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('selected node preference is committed to memory and disk', () async {
    final service = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );

    await service.updateLastSelectedNodeName('新加坡节点');

    expect(service.settings.lastSelectedNodeName, '新加坡节点');
    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted['lastSelectedNodeName'], '新加坡节点');
  });

  test('legacy JSON secret is moved to secure storage and scrubbed from disk',
      () async {
    await File(settingsPath).writeAsString(
      jsonEncode(
        AppSettings(proxyPort: 7899, apiSecret: 'json-secret').toJson(),
      ),
    );
    final writes = <String>[];
    String? secureSecret;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async {
        writes.add(value);
        secureSecret = value;
      },
    );

    expect(writes, ['json-secret']);
    expect(service.settings.apiSecret, 'json-secret');
    expect(service.settings.proxyPort, 7899);

    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
    expect(persisted.values, isNot(contains('json-secret')));
  });

  test('existing secure secret wins over legacy JSON and scrubs the stale copy',
      () async {
    await File(settingsPath).writeAsString(
      jsonEncode(AppSettings(apiSecret: 'json-secret').toJson()),
    );
    var writes = 0;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async => writes += 1,
    );

    expect(service.settings.apiSecret, 'secure-secret');
    expect(writes, 0);

    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
    expect(persisted.values, isNot(contains('json-secret')));
  });

  test('ordinary settings saves never write the secure secret to JSON',
      () async {
    await File(settingsPath).writeAsString(
      jsonEncode(AppSettings(proxyPort: 7890).toJson()..remove('apiSecret')),
    );
    var writes = 0;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async => writes += 1,
    );
    await service.updateProxyPort(8890);

    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted['proxyPort'], 8890);
    expect(persisted.containsKey('apiSecret'), isFalse);
    expect(persisted.values, isNot(contains('secure-secret')));
    expect(writes, 0);
  });

  test('failed legacy migration keeps the JSON secret', () async {
    await File(settingsPath).writeAsString(
      jsonEncode(AppSettings(apiSecret: 'json-secret').toJson()),
    );

    await expectLater(
      SettingsService.createForTesting(
        dataDir: tempDirectory.path,
        settingsPath: settingsPath,
        readApiSecret: () async => null,
        writeApiSecret: (_) async => throw StateError('keychain unavailable'),
      ),
      throwsA(isA<StateError>()),
    );

    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted['apiSecret'], 'json-secret');
  });

  test('default macOS secret file is separate and mode 0600', () async {
    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
    );

    final secretFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}.api-secret',
    );
    expect(await secretFile.readAsString(), service.settings.apiSecret);
    expect((await secretFile.stat()).mode & 0x1ff, 0x180);
    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
  });

  test('startup removes a crash-left API secret temporary file', () async {
    final stale = File(
      '${tempDirectory.path}${Platform.pathSeparator}.api-secret.tmp.crash',
    );
    await stale.writeAsString('old-plaintext-secret', flush: true);

    await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
    );

    expect(await stale.exists(), isFalse);
  });

  test('existing macOS secret file is tightened before it is read', () async {
    final secretFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}.api-secret',
    );
    await secretFile.writeAsString('stored-secret');
    final chmod = await Process.run('/bin/chmod', ['644', secretFile.path]);
    expect(chmod.exitCode, 0);
    await File(settingsPath).writeAsString(
      jsonEncode(AppSettings(apiSecret: 'stale-json-secret').toJson()),
    );

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
    );

    expect(service.settings.apiSecret, 'stored-secret');
    expect((await secretFile.stat()).mode & 0x1ff, 0x180);
    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
  });

  test('default macOS secret store rejects a symlink data directory', () async {
    final target = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}target',
    );
    await target.create();
    final linkedDataDir =
        '${tempDirectory.path}${Platform.pathSeparator}linked-data';
    await Link(linkedDataDir).create(target.path);

    await expectLater(
      SettingsService.createForTesting(
        dataDir: linkedDataDir,
        settingsPath: '$linkedDataDir${Platform.pathSeparator}settings.json',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('verified migration removes the legacy SharedPreferences copy',
      () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(
        AppSettings(proxyPort: 8890, apiSecret: 'preferences-secret').toJson(),
      ),
    });
    String? storedSecret;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => storedSecret,
      writeApiSecret: (value) async => storedSecret = value,
    );

    expect(service.settings.proxyPort, 8890);
    expect(service.settings.apiSecret, 'preferences-secret');
    expect(storedSecret, 'preferences-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('app_settings'), isFalse);
    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
  });

  test('invalid legacy SharedPreferences keeps its secret and self-recovers',
      () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        ...AppSettings(apiSecret: 'preferences-secret').toJson(),
        'lastSelectedNodeName': 42,
      }),
    });
    String? secureSecret;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async => secureSecret = value,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('app_settings'), isFalse);
    expect(secureSecret, 'preferences-secret');
    expect(service.settings.apiSecret, 'preferences-secret');
    expect(service.settings.lastSelectedNodeName, isNull);
    final persisted = await File(settingsPath).readAsString();
    expect(persisted, isNot(contains('preferences-secret')));
    expect(persisted, isNot(contains('apiSecret')));
  });

  test('valid modern settings ignore and remove malformed legacy preferences',
      () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        ...AppSettings(apiSecret: 'legacy-secret').toJson(),
        'lastSelectedNodeName': 42,
      }),
    });
    await File(settingsPath).writeAsString(
      jsonEncode(
        AppSettings(proxyPort: 8890).toJson()..remove('apiSecret'),
      ),
    );
    var writes = 0;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => 'modern-secret',
      writeApiSecret: (_) async => writes += 1,
    );

    expect(service.settings.proxyPort, 8890);
    expect(service.settings.apiSecret, 'modern-secret');
    expect(writes, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('app_settings'), isFalse);
  });

  for (final removalFailure in <String, Future<bool> Function()>{
    'returns false': () async => false,
    'throws': () async => throw StateError('preference store unavailable'),
  }.entries) {
    test(
        'valid modern state still starts when retired preference cleanup '
        '${removalFailure.key}', () async {
      await File(settingsPath).writeAsString(
        jsonEncode(AppSettings(proxyPort: 7899).toJson()..remove('apiSecret')),
        flush: true,
      );
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(
          AppSettings(apiSecret: 'retired-plaintext-secret').toJson(),
        ),
      });

      final service = await SettingsService.createForTesting(
        dataDir: tempDirectory.path,
        settingsPath: settingsPath,
        readApiSecret: () async => 'secure-secret',
        writeApiSecret: (_) async => fail('secure secret must be preserved'),
        removeLegacyPreferences: removalFailure.value,
      );

      expect(service.settings.apiSecret, 'secure-secret');
      expect(service.settings.proxyPort, 7899);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('app_settings'), isTrue);
    });
  }

  test('typed-invalid settings backup is scrubbed before startup recovers',
      () async {
    await File(settingsPath).writeAsString(
      jsonEncode({
        ...AppSettings(apiSecret: 'plaintext-secret').toJson(),
        'lastSelectedNodeName': 42,
      }),
    );
    String? storedSecret;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => storedSecret,
      writeApiSecret: (value) async => storedSecret = value,
    );

    expect(service.settings.apiSecret, 'plaintext-secret');
    expect(storedSecret, 'plaintext-secret');
    final backups = await tempDirectory
        .list()
        .where((entry) => entry.path.contains('settings.json.bad-'))
        .where((entry) => !entry.path.endsWith('.reason.txt'))
        .toList();
    expect(backups, hasLength(1));
    final backupText = await File(backups.single.path).readAsString();
    expect(backupText, isNot(contains('plaintext-secret')));
    expect(backupText, isNot(contains('apiSecret')));
    final persisted = await File(settingsPath).readAsString();
    expect(persisted, isNot(contains('plaintext-secret')));
    expect(persisted, isNot(contains('apiSecret')));
  });

  test(
      'truncated modern settings self-recovers without retaining raw plaintext',
      () async {
    await File(settingsPath).writeAsString(
      '{"apiSecret":"plaintext-secret"',
      flush: true,
    );

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async => fail('secure secret must be preserved'),
    );

    expect(service.settings.apiSecret, 'secure-secret');
    final entries = await tempDirectory
        .list()
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    for (final entry in entries) {
      expect(
        await entry.readAsString(),
        isNot(contains('plaintext-secret')),
        reason: entry.path,
      );
    }
    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
  });

  test('syntactically malformed legacy preferences are retired safely',
      () async {
    SharedPreferences.setMockInitialValues({'app_settings': '{'});
    String? secureSecret;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async => secureSecret = value,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('app_settings'), isFalse);
    expect(secureSecret, service.settings.apiSecret);
    expect(secureSecret, isNotEmpty);
    expect(await File(settingsPath).exists(), isTrue);
  });

  test('wrongly typed legacy preferences cannot permanently block startup',
      () async {
    SharedPreferences.setMockInitialValues({'app_settings': 42});

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async => fail('secure secret must be preserved'),
    );

    expect(service.settings.apiSecret, 'secure-secret');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('app_settings'), isFalse);
    expect(await File(settingsPath).exists(), isTrue);
  });

  test('typed-invalid settings stays intact when secret migration fails',
      () async {
    await File(settingsPath).writeAsString(
      jsonEncode({
        ...AppSettings(apiSecret: 'plaintext-secret').toJson(),
        'lastSelectedNodeName': 42,
      }),
    );

    await expectLater(
      SettingsService.createForTesting(
        dataDir: tempDirectory.path,
        settingsPath: settingsPath,
        readApiSecret: () async => null,
        writeApiSecret: (_) async => throw StateError('secret store offline'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(
        await File(settingsPath).readAsString(), contains('plaintext-secret'));
    final backups = await tempDirectory
        .list()
        .where((entry) => entry.path.contains('settings.json.bad-'))
        .toList();
    expect(backups, isEmpty);
  });

  test('failed API secret rotation restores the previous durable value',
      () async {
    var secureSecret = 'old-secret';
    var failNewValueRead = true;
    final service = await SettingsService.createForTesting(
      settings: AppSettings(apiSecret: secureSecret),
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async {
        if (secureSecret == 'new-secret' && failNewValueRead) {
          failNewValueRead = false;
          throw StateError('keychain verification unavailable');
        }
        return secureSecret;
      },
      writeApiSecret: (value) async => secureSecret = value,
    );

    await expectLater(
      service.updateApiSecret('new-secret'),
      throwsA(isA<StateError>()),
    );

    expect(secureSecret, 'old-secret');
    expect(service.settings.apiSecret, 'old-secret');
  });

  test('reset and API secret update share one serial transaction queue',
      () async {
    var secureSecret = 'old-secret';
    final writes = <String>[];
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    var activeWrites = 0;
    var maxActiveWrites = 0;
    final service = await SettingsService.createForTesting(
      settings: AppSettings(apiSecret: secureSecret),
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async {
        activeWrites += 1;
        if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
        writes.add(value);
        if (writes.length == 1) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
        secureSecret = value;
        activeWrites -= 1;
      },
    );

    final reset = service.resetAppData();
    await firstWriteStarted.future;
    final update = service.updateApiSecret('after-reset');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final writesBeforeRelease = writes.length;
    releaseFirstWrite.complete();
    await Future.wait([reset, update]);

    expect(writesBeforeRelease, 1);
    expect(maxActiveWrites, 1);
    expect(writes.last, 'after-reset');
    expect(secureSecret, 'after-reset');
    expect(service.settings.apiSecret, 'after-reset');
  });

  test('failed reset keeps user data and the previous API secret', () async {
    final subscriptionFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}subscriptions.json',
    );
    await subscriptionFile.writeAsString('keep-me');
    var secureSecret = 'old-secret';
    var failReplacementRead = true;
    final service = await SettingsService.createForTesting(
      settings: AppSettings(apiSecret: secureSecret, proxyPort: 8890),
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async {
        if (secureSecret != 'old-secret' && failReplacementRead) {
          failReplacementRead = false;
          throw StateError('keychain verification unavailable');
        }
        return secureSecret;
      },
      writeApiSecret: (value) async => secureSecret = value,
    );

    await expectLater(service.resetAppData(), throwsA(isA<StateError>()));

    expect(await subscriptionFile.readAsString(), 'keep-me');
    expect(secureSecret, 'old-secret');
    expect(service.settings.apiSecret, 'old-secret');
    expect(service.settings.proxyPort, 8890);
  });

  test('settings commit failure rolls reset back before deleting user data',
      () async {
    final oldSettings = AppSettings(apiSecret: 'old-secret', proxyPort: 8890);
    final oldSettingsText = jsonEncode(
      oldSettings.toJson()..remove('apiSecret'),
    );
    await File(settingsPath).writeAsString(oldSettingsText);
    final subscriptionFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}subscriptions.json',
    );
    await subscriptionFile.writeAsString('keep-me');
    var secureSecret = 'old-secret';
    final secretWrites = <String>[];
    final service = await SettingsService.createForTesting(
      settings: oldSettings,
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async {
        secretWrites.add(value);
        secureSecret = value;
      },
      writeSettings: (_) async => throw const FileSystemException(
        'simulated settings rename/fsync failure',
      ),
    );

    await expectLater(
      service.resetAppData(),
      throwsA(isA<FileSystemException>()),
    );

    expect(secretWrites, hasLength(2));
    expect(secretWrites.last, 'old-secret');
    expect(secureSecret, 'old-secret');
    expect(service.settings, oldSettings);
    expect(await File(settingsPath).readAsString(), oldSettingsText);
    expect(await subscriptionFile.readAsString(), 'keep-me');
  });

  test('reset reports data entries it could not delete', () async {
    final blockedEntry = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}subscriptions.json',
    );
    await blockedEntry.create();
    var secureSecret = 'old-secret';
    final service = await SettingsService.createForTesting(
      settings: AppSettings(apiSecret: secureSecret),
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async => secureSecret = value,
    );

    await expectLater(service.resetAppData(), throwsA(isA<StateError>()));

    expect(await blockedEntry.exists(), isTrue);
    expect(service.settings.proxyPort, AppSettings().proxyPort);
    expect(secureSecret, service.settings.apiSecret);
  });

  test('reset removes crash-left API secret temporary files', () async {
    var secureSecret = 'old-secret';
    final service = await SettingsService.createForTesting(
      settings: AppSettings(apiSecret: secureSecret),
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async => secureSecret = value,
    );
    final stale = File(
      '${tempDirectory.path}${Platform.pathSeparator}.api-secret.tmp.crash',
    );
    await stale.writeAsString('old-plaintext-secret', flush: true);

    await service.resetAppData();

    expect(await stale.exists(), isFalse);
  });
}
