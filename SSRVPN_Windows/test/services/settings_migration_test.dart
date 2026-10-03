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

  Future<String> linkLocalAlias() async {
    final alias = path.normalize(path.join(root.path, 'local-alias'));
    if (Platform.isWindows) {
      final result = await Process.run('cmd.exe', [
        '/d',
        '/c',
        'mklink',
        '/J',
        alias,
        path.normalize(path.join(root.path, 'local'))
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    } else {
      await Link(alias).create('${root.path}/local');
    }
    return alias;
  }

  Future<void> sourceAccess(bool allow,
      {bool readable = false, String? entityPath}) async {
    final protectedPath = entityPath ?? installed.path;
    if (Platform.isWindows) {
      final identity =
          await Process.run('whoami.exe', ['/user', '/fo', 'csv', '/nh']);
      expect(identity.exitCode, 0);
      final sid = RegExp(r'S-1-[0-9-]+')
          .firstMatch(identity.stdout as String)!
          .group(0)!;
      final result = await Process.run('icacls.exe', [
        protectedPath,
        allow ? '/remove:d' : '/deny',
        allow ? '*$sid' : '*$sid:${readable ? '(W)' : '(R,W)'}',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
    } else {
      final result = await Process.run(
          'chmod', [allow ? '700' : (readable ? '555' : '000'), protectedPath]);
      expect(result.exitCode, 0);
    }
  }

  test('unreadable source cannot commit an empty authoritative store',
      () async {
    await File('${installed.path}/subscriptions.json')
        .writeAsString('["retained"]');
    await sourceAccess(false);
    try {
      await expectLater(migrate(), throwsA(isA<FileSystemException>()));
      expect(await marker.exists(), isFalse);
      expect(await targetSettings.exists(), isFalse);
    } finally {
      await sourceAccess(true);
    }
    await migrate();
    expect((await settings())['proxyPort'], 7890);
    expect(await File('${fallback.path}/subscriptions.json').readAsString(),
        '["retained"]');
  });

  test('listable source without traversal cannot commit migration', () async {
    expect((await Process.run('chmod', ['444', installed.path])).exitCode, 0);
    try {
      await expectLater(migrate(), throwsA(isA<FileSystemException>()));
      expect(await marker.exists(), isFalse);
    } finally {
      expect((await Process.run('chmod', ['700', installed.path])).exitCode, 0);
    }
  }, skip: Platform.isWindows);

  test('unreadable committed fallback cannot select stale installed data',
      () async {
    await migrate();
    await targetSettings
        .writeAsString(jsonEncode({...await settings(), 'proxyPort': 8890}));
    await sourceAccess(false, entityPath: fallback.path);
    try {
      await expectLater(resolve(), throwsA(isA<FileSystemException>()));
    } finally {
      await sourceAccess(true, entityPath: fallback.path);
    }
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect((await settings())['proxyPort'], 8890);
  });

  test('unreadable marker cannot masquerade as an uncommitted fallback',
      () async {
    await migrate();
    await sourceAccess(false, entityPath: marker.path);
    try {
      await expectLater(resolve(), throwsA(isA<FileSystemException>()));
    } finally {
      await sourceAccess(true, entityPath: marker.path);
    }
    expect(path.equals(await resolve(), fallback.path), isTrue);
  });

  test('Windows marker lookup preserves case-insensitive file names', () async {
    await migrate();
    await targetSettings
        .writeAsString(jsonEncode({...await settings(), 'proxyPort': 8890}));
    await marker.rename(
        '${fallback.path}/${WindowsSettingsMigration.markerName.toUpperCase()}');
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect((await settings())['proxyPort'], 8890);
  }, skip: !Platform.isWindows);

  test('readable read-only source still migrates normally', () async {
    await sourceAccess(false, readable: true);
    try {
      await migrate();
      expect((await settings())['proxyPort'], 7890);
      expect(await marker.exists(), isTrue);
    } finally {
      await sourceAccess(true);
    }
  });

  test('an unreadable optional cache does not prevent metadata migration',
      () async {
    final cache = File('${installed.path}/node-latencies.json');
    await cache.writeAsString('{"retained":1}');
    await sourceAccess(false, entityPath: cache.path);
    try {
      await migrate();
      expect(await marker.exists(), isTrue);
      expect((await settings())['proxyPort'], 7890);
    } finally {
      await sourceAccess(true, entityPath: cache.path);
    }
    expect(await cache.readAsString(), '{"retained":1}');
  });

  Future<File> interruptBackground({bool removeSource = true}) async {
    final before = await sourceSettings.readAsBytes();
    await migrate();
    await targetSettings.writeAsBytes(before, flush: true);
    if (removeSource) await installed.delete(recursive: true);
    return File('${fallback.path}/backgrounds/image-example/background.png');
  }

  test('interrupted JSON commit recovers verified copy after source removal',
      () async {
    final target = await interruptBackground();
    await targetSettings
        .writeAsString(jsonEncode({...await settings(), 'proxyPort': 8890}));
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect(
        path.equals(
            (await settings())['customBackgroundPath'] as String, target.path),
        isTrue);
    expect(await target.readAsBytes(), [1, 2, 3, 4]);
    expect((await settings())['proxyPort'], 8890);
  });

  test('source-free recovery rejects changed image and preserves reference',
      () async {
    final target = await interruptBackground();
    final before = await targetSettings.readAsString();
    await target.writeAsBytes([9]);
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect(await targetSettings.readAsString(), before);
    expect(await target.readAsBytes(), [9]);
  });

  test('source-free recovery cannot adopt a copy without its receipt',
      () async {
    final target = await interruptBackground();
    await File('${target.parent.path}/.migration-receipt.json').delete();
    final before = await targetSettings.readAsString();
    await migrate();
    expect(await targetSettings.readAsString(), before);
  });

  test('source-free recovery rejects corrupt or mismatched receipts', () async {
    final target = await interruptBackground();
    final receipt = File('${target.parent.path}/.migration-receipt.json');
    final valid =
        jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
    final before = await targetSettings.readAsString();
    for (final invalid in [
      '{broken',
      jsonEncode({...valid, 'source': '${root.path}/other.png'})
    ]) {
      await receipt.writeAsString(invalid);
      await expectLater(
          migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
      expect(await targetSettings.readAsString(), before);
    }
  });

  test('source-free recovery rejects a linked receipt', () async {
    final target = await interruptBackground();
    final receipt = File('${target.parent.path}/.migration-receipt.json');
    final elsewhere = File('${root.path}/private-receipt.json');
    await elsewhere.writeAsBytes(await receipt.readAsBytes());
    await receipt.delete();
    await Link(receipt.path).create(elsewhere.path);
    final before = await targetSettings.readAsString();
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect(await targetSettings.readAsString(), before);
    expect(await elsewhere.exists(), isTrue);
  }, skip: Platform.isWindows);

  test('receipt alone never commits a missing target after interruption',
      () async {
    final target = await interruptBackground();
    await target.delete();
    final before = await targetSettings.readAsString();
    await expectLater(
        migrate(), throwsA(isA<WindowsBackgroundMigrationPending>()));
    expect(await targetSettings.readAsString(), before);
  });

  test('retained receipt cannot overwrite a newly selected background',
      () async {
    await interruptBackground();
    await targetSettings.writeAsString(jsonEncode(
        {...await settings(), 'customBackgroundPath': '${root.path}/new.png'}));
    final before = await targetSettings.readAsString();
    await migrate();
    expect(await targetSettings.readAsString(), before);
  });

  test('linked ancestor cannot redirect authoritative data', () async {
    await migrate();
    final alias = await linkLocalAlias();
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

  test('linked destination ancestor is rejected before initial copy', () async {
    final alias = await linkLocalAlias();
    try {
      await expectLater(
          SettingsService.migrateInstalledDataForTesting(
              installed.path, '$alias/SSRVPN/ssrvpn'),
          throwsA(isA<FileSystemException>()));
      expect(await targetSettings.exists(), isFalse);
      expect(await marker.exists(), isFalse);
      expect(await sourceSettings.exists(), isTrue);
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
