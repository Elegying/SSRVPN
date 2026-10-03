import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:ssrvpn_windows/services/settings_service.dart';
import 'package:ssrvpn_windows/services/windows_settings_migration.dart';

void main() {
  late Directory root, installed, fallback;
  late File sourceSettings, targetSettings, marker, picture;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('windows-data-migration-');
    installed =
        await Directory('${root.path}/bin/ssrvpn').create(recursive: true);
    fallback = await Directory('${root.path}/local/SSRVPN/ssrvpn')
        .create(recursive: true);
    sourceSettings = File('${installed.path}/settings.json');
    targetSettings = File('${fallback.path}/settings.json');
    marker = File('${fallback.path}/${WindowsSettingsMigration.markerName}');
    picture =
        File('${installed.path}/backgrounds/image-example/background.png');
    await picture.parent.create(recursive: true);
    await picture.writeAsBytes([1, 2, 3, 4]);
    await sourceSettings.writeAsString(jsonEncode({
      'proxyPort': 7890,
      'backgroundStyle': 'custom',
      'customBackgroundPath': picture.path
    }));
  });
  tearDown(() => root.delete(recursive: true));
  Future<String> resolve() => SettingsService.resolveDataDirectoryForTesting(
      '${root.path}/bin/SSRVPN.exe', '${root.path}/local');
  Future<Map<String, dynamic>> settings() async =>
      jsonDecode(await targetSettings.readAsString()) as Map<String, dynamic>;
  Future<void> migrate() => SettingsService.migrateInstalledDataForTesting(
      installed.path, fallback.path);

  test('linked ancestor cannot redirect authoritative data', () async {
    await migrate();
    final alias = '${root.path}/local-alias';
    if (Platform.isWindows) {
      final result = await Process.run(
          'cmd.exe', ['/d', '/c', 'mklink', '/J', alias, '${root.path}/local']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    } else {
      await Link(alias).create('${root.path}/local');
    }
    try {
      await expectLater(
          SettingsService.resolveDataDirectoryForTesting(
              '${root.path}/bin/SSRVPN.exe', alias),
          throwsA(isA<FileSystemException>()));
      expect((await settings())['proxyPort'], 7890);
      expect(await picture.readAsBytes(), [1, 2, 3, 4]);
    } finally {
      await Link(alias).delete();
    }
  });

  test('completed fallback stays authoritative after source becomes writable',
      () async {
    await migrate();
    await targetSettings
        .writeAsString(jsonEncode({...await settings(), 'proxyPort': 8890}));
    await File('${installed.path}/subscriptions.json').writeAsString('["old"]');
    await File('${fallback.path}/subscriptions.json').writeAsString('["new"]');
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect((await settings())['proxyPort'], 8890);
    expect(await File('${fallback.path}/subscriptions.json').readAsString(),
        '["new"]');
  });
  test('completed fallback remains authoritative after source removal',
      () async {
    await migrate();
    await installed.delete(recursive: true);
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect(
        await File((await settings())['customBackgroundPath'] as String)
            .readAsBytes(),
        [1, 2, 3, 4]);
  });
  test('background survives source removal without changing unrelated settings',
      () async {
    await migrate();
    final saved = await settings();
    expect(saved['proxyPort'], 7890);
    expect(saved['backgroundStyle'], 'custom');
    final savedPicture = File(saved['customBackgroundPath'] as String);
    expect(
        path.equals(savedPicture.path,
            '${fallback.path}/backgrounds/image-example/background.png'),
        isTrue);
    expect(await picture.readAsBytes(), [1, 2, 3, 4]);
    await installed.delete(recursive: true);
    expect(await savedPicture.readAsBytes(), [1, 2, 3, 4]);
  });
  test('legacy marker repairs only the currently referenced background',
      () async {
    await marker.writeAsString('1\n');
    await targetSettings.writeAsString(
        jsonEncode({'proxyPort': 8890, 'customBackgroundPath': picture.path}));
    await migrate();
    expect((await settings())['proxyPort'], 8890);
    expect(
        path.isWithin(fallback.path,
            (await settings())['customBackgroundPath'] as String),
        isTrue);
  });
  test('conflicting image retains both copies and setting then retries safely',
      () async {
    await marker.writeAsString('1\n');
    await targetSettings.writeAsString(await sourceSettings.readAsString());
    final target =
        File('${fallback.path}/backgrounds/image-example/background.png');
    await target.parent.create(recursive: true);
    await target.writeAsBytes([9]);
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect((await settings())['customBackgroundPath'], picture.path);
    expect(await target.readAsBytes(), [9]);
    expect(await picture.readAsBytes(), [1, 2, 3, 4]);
    await target.delete();
    await migrate();
    expect(
        path.equals(
            (await settings())['customBackgroundPath'] as String, target.path),
        isTrue);
  });
  test(
      'initial background failure commits authority without replaying old metadata',
      () async {
    final target =
        File('${fallback.path}/backgrounds/image-example/background.png');
    await target.parent.create(recursive: true);
    await target.writeAsBytes([9]);
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect(await marker.readAsString(), '1\n');
    expect(path.equals(await resolve(), fallback.path), isTrue);
    await targetSettings
        .writeAsString(jsonEncode({...await settings(), 'proxyPort': 8890}));
    await target.delete();
    await migrate();
    expect((await settings())['proxyPort'], 8890);
  });
  test('external file paths are retained without importing unrelated files',
      () async {
    final unrelated = File('${root.path}/personal.png');
    await unrelated.writeAsBytes([7]);
    await sourceSettings
        .writeAsString(jsonEncode({'customBackgroundPath': unrelated.path}));
    await migrate();
    expect((await settings())['customBackgroundPath'], unrelated.path);
    expect(await unrelated.readAsBytes(), [7]);
    expect(await Directory('${fallback.path}/backgrounds').exists(), isFalse);
  });
  test('missing source image does not prevent access to migrated subscriptions',
      () async {
    await picture.delete();
    await migrate();
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect((await settings())['customBackgroundPath'], picture.path);
  });
  test('damaged marker cannot silently select stale installed data', () async {
    await marker.writeAsString('broken');
    await expectLater(resolve(), throwsFormatException);
    expect(await sourceSettings.exists(), isTrue);
  });
  test('uncommitted migration retains critical metadata conflict protections',
      () async {
    await targetSettings.writeAsString('{"proxyPort":8890}');
    await expectLater(migrate(), throwsStateError);
    expect(await marker.exists(), isFalse);
    expect(await targetSettings.readAsString(), '{"proxyPort":8890}');
  });
  test('a new fallback without an installed source also commits authority',
      () async {
    await installed.delete(recursive: true);
    await migrate();
    expect(await marker.readAsString(), '1\n');
    await installed.create(recursive: true);
    expect(path.equals(await resolve(), fallback.path), isTrue);
  });
  test('corrupt settings are left for normal startup recovery', () async {
    await marker.writeAsString('1');
    await targetSettings.writeAsString('{broken');
    await migrate();
    expect(await targetSettings.readAsString(), '{broken');
  });
  test('oversized background preserves the old reference and allows startup',
      () async {
    final handle = await picture.open(mode: FileMode.write);
    await handle.truncate(20 * 1024 * 1024 + 1);
    await handle.close();
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect((await settings())['customBackgroundPath'], picture.path);
    expect(path.equals(await resolve(), fallback.path), isTrue);
  });
  test('non-directory background target is retained and can be retried',
      () async {
    final obstacle = File('${fallback.path}/backgrounds');
    await obstacle.writeAsString('user file');
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect(await obstacle.readAsString(), 'user file');
    expect((await settings())['customBackgroundPath'], picture.path);
    await obstacle.delete();
    await migrate();
    expect(
        path.isWithin(fallback.path,
            (await settings())['customBackgroundPath'] as String),
        isTrue);
  });
  test('linked image is rejected without touching its target', () async {
    final elsewhere = File('${root.path}/private.png');
    await elsewhere.writeAsBytes([7]);
    await picture.delete();
    await Link(picture.path).create(elsewhere.path);
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect(await elsewhere.readAsBytes(), [7]);
    expect((await settings())['customBackgroundPath'], picture.path);
  }, skip: Platform.isWindows);
}
