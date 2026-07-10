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
    final persisted = await File(configPath).readAsString();
    expect(persisted, isNot(contains('apiSecret')));
    expect(persisted, isNot(contains('new-secret')));
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
}
