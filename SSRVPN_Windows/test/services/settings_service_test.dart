import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/settings_service.dart';

void main() {
  late Directory tempDirectory;
  late String settingsPath;

  setUp(() async {
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
        writeApiSecret: (_) async => throw StateError('credential unavailable'),
      ),
      throwsA(isA<StateError>()),
    );

    final persisted = jsonDecode(await File(settingsPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted['apiSecret'], 'json-secret');
  });

  test('typed legacy JSON failure still migrates and scrubs its API secret',
      () async {
    final legacy = AppSettings(
      apiSecret: 'recoverable-secret',
      proxyPort: 8890,
    ).toJson()
      ..['proxyMode'] = 123;
    await File(settingsPath).writeAsString(jsonEncode(legacy));
    String? secureSecret;

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async => secureSecret = value,
    );

    expect(service.settings.apiSecret, 'recoverable-secret');
    expect(secureSecret, 'recoverable-secret');
    final files = await tempDirectory
        .list()
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    expect(files.any((file) => file.path.contains('.bad-')), isTrue);
    for (final file in files) {
      expect(await file.readAsString(), isNot(contains('recoverable-secret')));
    }
  });

  test('malformed settings backup omits potentially sensitive raw content',
      () async {
    await File(settingsPath).writeAsString(
      '{"apiSecret":"raw-legacy-secret",',
    );

    final service = await SettingsService.createForTesting(
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async {},
    );

    expect(service.settings.apiSecret, 'secure-secret');
    final files = await tempDirectory
        .list()
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    expect(files.any((file) => file.path.contains('.bad-')), isTrue);
    for (final file in files) {
      expect(await file.readAsString(), isNot(contains('raw-legacy-secret')));
    }
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
          throw StateError('credential verification unavailable');
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
          throw StateError('credential verification unavailable');
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

  test('settings write failure rolls back a prepared reset transaction',
      () async {
    final oldSettings = AppSettings(apiSecret: 'old-secret', proxyPort: 8890);
    final oldSettingsJson = jsonEncode(
      oldSettings.toJson()..remove('apiSecret'),
    );
    await File(settingsPath).writeAsString(oldSettingsJson, flush: true);
    final subscriptionFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}subscriptions.json',
    );
    await subscriptionFile.writeAsString('keep-me');
    var secureSecret = 'old-secret';
    final service = await SettingsService.createForTesting(
      settings: oldSettings,
      dataDir: tempDirectory.path,
      settingsPath: settingsPath,
      readApiSecret: () async => secureSecret,
      writeApiSecret: (value) async => secureSecret = value,
      writeSettings: (_) async => throw StateError('settings disk offline'),
    );

    await expectLater(service.resetAppData(), throwsA(isA<StateError>()));

    expect(secureSecret, 'old-secret');
    expect(service.settings.apiSecret, 'old-secret');
    expect(service.settings.proxyPort, 8890);
    expect(await File(settingsPath).readAsString(), oldSettingsJson);
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

  test('installed fallback migration preserves all critical user data',
      () async {
    final installed =
        await Directory.systemTemp.createTemp('ssrvpn-installed-');
    final fallback = await Directory.systemTemp.createTemp('ssrvpn-fallback-');
    addTearDown(() => installed.delete(recursive: true));
    addTearDown(() => fallback.delete(recursive: true));
    const critical = {
      '.api-secret.dpapi': 'encrypted-secret',
      'settings.json': '{"proxyPort":8890}',
      'subscriptions.json': '["feed"]',
    };
    for (final entry in critical.entries) {
      await File(
        '${installed.path}${Platform.pathSeparator}${entry.key}',
      ).writeAsString(entry.value, flush: true);
    }

    await SettingsService.migrateInstalledDataForTesting(
      installed.path,
      fallback.path,
    );

    for (final entry in critical.entries) {
      expect(
        await File(
          '${fallback.path}${Platform.pathSeparator}${entry.key}',
        ).readAsString(),
        entry.value,
      );
    }
  });

  test('completed installed migration does not replay stale source data',
      () async {
    final installed =
        await Directory.systemTemp.createTemp('ssrvpn-installed-');
    final fallback = await Directory.systemTemp.createTemp('ssrvpn-fallback-');
    addTearDown(() => installed.delete(recursive: true));
    addTearDown(() => fallback.delete(recursive: true));
    final source = File(
      '${installed.path}${Platform.pathSeparator}subscriptions.json',
    );
    final destination = File(
      '${fallback.path}${Platform.pathSeparator}subscriptions.json',
    );
    await source.writeAsString('["installed"]', flush: true);

    await SettingsService.migrateInstalledDataForTesting(
      installed.path,
      fallback.path,
    );
    await destination.writeAsString('["updated-fallback"]', flush: true);

    await SettingsService.migrateInstalledDataForTesting(
      installed.path,
      fallback.path,
    );

    expect(await destination.readAsString(), '["updated-fallback"]');
  });

  test('installed fallback conflict fails without overwriting either copy',
      () async {
    final installed =
        await Directory.systemTemp.createTemp('ssrvpn-installed-');
    final fallback = await Directory.systemTemp.createTemp('ssrvpn-fallback-');
    addTearDown(() => installed.delete(recursive: true));
    addTearDown(() => fallback.delete(recursive: true));
    final source = File(
      '${installed.path}${Platform.pathSeparator}subscriptions.json',
    );
    final destination = File(
      '${fallback.path}${Platform.pathSeparator}subscriptions.json',
    );
    await source.writeAsString('["installed"]', flush: true);
    await destination.writeAsString('["fallback"]', flush: true);

    await expectLater(
      SettingsService.migrateInstalledDataForTesting(
        installed.path,
        fallback.path,
      ),
      throwsA(isA<StateError>()),
    );

    expect(await source.readAsString(), '["installed"]');
    expect(await destination.readAsString(), '["fallback"]');
  });
}
