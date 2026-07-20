import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late String configPath;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDirectory = await Directory.systemTemp.createTemp('ssrvpn-settings-');
    configPath = '${tempDirectory.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('secure-storage read failures abort initialization without rotation',
      () async {
    var writes = 0;

    await expectLater(
      SettingsService.createForTesting(
        configPath: configPath,
        readApiSecret: () async => throw StateError('keystore unavailable'),
        writeApiSecret: (_) async => writes += 1,
      ),
      throwsA(isA<StateError>()),
    );

    expect(writes, 0);
  });

  test('failed legacy migration keeps the legacy secret', () async {
    final encoded = base64Encode(utf8.encode('legacy-secret'));
    SharedPreferences.setMockInitialValues({'api_secret_enc': 'b64:$encoded'});

    await expectLater(
      SettingsService.createForTesting(
        configPath: configPath,
        readApiSecret: () async => null,
        writeApiSecret: (_) async => throw StateError('keystore unavailable'),
      ),
      throwsA(isA<StateError>()),
    );

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('api_secret_enc'), 'b64:$encoded');
  });

  test('successful legacy migration removes the source after secure write',
      () async {
    final encoded = base64Encode(utf8.encode('legacy-secret'));
    SharedPreferences.setMockInitialValues({'api_secret_enc': 'b64:$encoded'});
    final writes = <String>[];

    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => null,
      writeApiSecret: (value) async => writes.add(value),
    );

    final preferences = await SharedPreferences.getInstance();
    expect(writes, ['legacy-secret']);
    expect(preferences.containsKey('api_secret_enc'), isFalse);
    expect(service.settings.apiSecret, 'legacy-secret');
  });

  test('existing secure secret removes a stale legacy copy', () async {
    SharedPreferences.setMockInitialValues({
      'api_secret_enc': 'stale-legacy-secret',
    });
    var writes = 0;

    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async => writes += 1,
    );

    final preferences = await SharedPreferences.getInstance();
    expect(service.settings.apiSecret, 'secure-secret');
    expect(preferences.containsKey('api_secret_enc'), isFalse);
    expect(writes, 0);
  });

  test('failed secret update is reported and restores the in-memory secret',
      () async {
    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'old-secret',
      writeApiSecret: (_) async => throw StateError('keystore unavailable'),
    );

    await expectLater(
      service.setApiSecret('new-secret'),
      throwsA(isA<StateError>()),
    );

    expect(service.settings.apiSecret, 'old-secret');
    final settingsFile = File(configPath);
    if (await settingsFile.exists()) {
      final persisted = await settingsFile.readAsString();
      expect(persisted, isNot(contains('apiSecret')));
      expect(persisted, isNot(contains('new-secret')));
    }
  });

  test('legacy JSON secret is moved to secure storage and scrubbed from disk',
      () async {
    await File(configPath).writeAsString(
      jsonEncode(
          AppSettings(proxyPort: 7899, apiSecret: 'json-secret').toJson()),
    );
    final writes = <String>[];

    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => null,
      writeApiSecret: (value) async => writes.add(value),
    );

    expect(writes, ['json-secret']);
    expect(service.settings.apiSecret, 'json-secret');
    expect(service.settings.proxyPort, 7899);

    final persisted = jsonDecode(await File(configPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted.containsKey('apiSecret'), isFalse);
    expect(persisted.values, isNot(contains('json-secret')));
  });

  test('failed node preference save rolls back and remains retryable',
      () async {
    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'secure-secret',
      writeApiSecret: (_) async {},
    );
    await service.setLastSelectedNodeName('节点 A');
    var notifications = 0;
    service.addListener(() => notifications += 1);

    await tempDirectory.delete(recursive: true);
    await File(tempDirectory.path).writeAsString('blocks settings directory');

    await expectLater(
      service.setLastSelectedNodeName('节点 B'),
      throwsA(isA<FileSystemException>()),
    );
    expect(service.settings.lastSelectedNodeName, '节点 A');
    expect(notifications, 0);

    await File(tempDirectory.path).delete();
    await tempDirectory.create(recursive: true);
    await service.setLastSelectedNodeName('节点 B');

    expect(service.settings.lastSelectedNodeName, '节点 B');
    expect(notifications, 1);
    final persisted = jsonDecode(await File(configPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted['lastSelectedNodeName'], '节点 B');
  });

  test('bulk settings updates cannot rotate the secure API secret', () async {
    var secretWrites = 0;
    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'old-secret',
      writeApiSecret: (_) async {
        secretWrites += 1;
        throw StateError('keystore unavailable');
      },
    );

    await service.updateSettings(
      AppSettings(proxyPort: 7901, apiSecret: 'untrusted-new-secret'),
    );

    expect(service.settings.proxyPort, 7901);
    expect(service.settings.apiSecret, 'old-secret');
    expect(secretWrites, 0);
    final persisted = jsonDecode(await File(configPath).readAsString())
        as Map<String, dynamic>;
    expect(persisted['proxyPort'], 7901);
    expect(persisted.containsKey('apiSecret'), isFalse);
  });

  test('bulk settings update snapshots mutable input before queueing',
      () async {
    final secretWriteStarted = Completer<void>();
    final releaseSecretWrite = Completer<void>();
    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'old-secret',
      writeApiSecret: (value) async {
        if (value == 'queued-secret') {
          secretWriteStarted.complete();
          await releaseSecretWrite.future;
        }
      },
    );

    final first = service.setApiSecret('queued-secret');
    await secretWriteStarted.future;

    final update = AppSettings(
      proxyPort: 7901,
      forceProxySites: const ['example.com'],
    );
    final second = service.updateSettings(update);
    update.proxyPort = 7999;
    update.forceProxySites[0] = 'mutated.example';

    releaseSecretWrite.complete();
    await first;
    await second;

    expect(service.settings.proxyPort, 7901);
    expect(
      service.settings.forceProxySites,
      ['example.com', '', '', '', ''],
    );
    expect(service.settings.apiSecret, 'queued-secret');
  });

  test('force proxy sites are copied before their queued update runs',
      () async {
    final secretWriteStarted = Completer<void>();
    final releaseSecretWrite = Completer<void>();
    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'old-secret',
      writeApiSecret: (value) async {
        if (value == 'queued-secret') {
          secretWriteStarted.complete();
          await releaseSecretWrite.future;
        }
      },
    );

    final first = service.setApiSecret('queued-secret');
    await secretWriteStarted.future;

    final sites = <String>['example.com'];
    final second = service.setForceProxySites(sites);
    sites.add('mutated.example');

    releaseSecretWrite.complete();
    await first;
    await second;

    expect(
      service.settings.forceProxySites,
      ['example.com', '', '', '', ''],
    );
  });

  test('a failed queued write does not poison the next settings update',
      () async {
    var failNextSecretWrite = true;
    final service = await SettingsService.createForTesting(
      configPath: configPath,
      readApiSecret: () async => 'old-secret',
      writeApiSecret: (_) async {
        if (failNextSecretWrite) {
          failNextSecretWrite = false;
          throw StateError('keystore unavailable');
        }
      },
    );

    final first = service.setApiSecret('failed-secret');
    final second = service.setLastSelectedNodeName('节点 C');

    await expectLater(first, throwsA(isA<StateError>()));
    await second;

    expect(service.settings.apiSecret, 'old-secret');
    expect(service.settings.lastSelectedNodeName, '节点 C');
  });
}
