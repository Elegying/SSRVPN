import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:ssrvpn_windows/services/settings_service.dart';
import 'package:ssrvpn_windows/services/windows_settings_migration.dart';

void main() {
  late Directory root, installed, fallback;
  late File sourceSettings, targetSettings, marker;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('windows-data-migration-');
    installed =
        await Directory('${root.path}/bin/ssrvpn').create(recursive: true);
    fallback = await Directory('${root.path}/local/SSRVPN/ssrvpn')
        .create(recursive: true);
    sourceSettings = File('${installed.path}/settings.json');
    targetSettings = File('${fallback.path}/settings.json');
    marker = File('${fallback.path}/${WindowsSettingsMigration.markerName}');
    await sourceSettings.writeAsString(jsonEncode({'proxyPort': 7890}));
  });
  tearDown(() => root.delete(recursive: true));
  Future<String> resolve() => SettingsService.resolveDataDirectoryForTesting(
      '${root.path}/bin/SSRVPN.exe', '${root.path}/local');
  Future<Map<String, dynamic>> settings() async =>
      jsonDecode(await targetSettings.readAsString()) as Map<String, dynamic>;
  Future<void> migrate() => SettingsService.migrateInstalledDataForTesting(
      installed.path, fallback.path);

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
      // Denying only a directory does not make child file data unreadable.
      final inherit = !allow &&
              !readable &&
              await FileSystemEntity.type(protectedPath) ==
                  FileSystemEntityType.directory
          ? '(OI)(CI)'
          : '';
      final result = await Process.run('icacls.exe', [
        protectedPath,
        allow ? '/remove:d' : '/deny',
        allow ? '*$sid' : '*$sid:$inherit${readable ? '(W)' : '(R,W)'}',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
    } else {
      final result = await Process.run(
          'chmod', [allow ? '700' : (readable ? '555' : '000'), protectedPath]);
      expect(result.exitCode, 0);
    }
  }

  test('committed fallback wins when installation becomes writable', () async {
    await migrate();
    await targetSettings.writeAsString(jsonEncode({'proxyPort': 8890}));
    expect(path.equals(await resolve(), fallback.path), isTrue);
    expect((await settings())['proxyPort'], 8890);
    expect(jsonDecode(await sourceSettings.readAsString())['proxyPort'], 7890);
  });

  test('unreadable source cannot commit an empty authoritative store',
      () async {
    await File('${installed.path}/subscriptions.json')
        .writeAsString('["retained"]');
    await sourceAccess(false);
    try {
      await expectLater(
          sourceSettings.readAsBytes(), throwsA(isA<FileSystemException>()),
          reason: 'The fixture must deny reading critical source data');
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

  test('a genuinely absent nested store has no committed migration', () async {
    expect(
        await WindowsSettingsMigration.isCommitted(
            path.join(root.path, 'absent', 'nested', 'store')),
        isFalse);
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
  test('invalid migration marker cannot fall back to stale installed data',
      () async {
    await marker.writeAsString('corrupt');
    await expectLater(resolve(), throwsA(isA<FormatException>()));
    expect(await marker.readAsString(), 'corrupt');
    expect(await targetSettings.exists(), isFalse);
  });

  test('Windows junction ancestor cannot redirect the authoritative store',
      () async {
    await migrate();
    final alias = path.join(root.path, 'local-alias');
    final result = await Process.run('cmd.exe',
        ['/d', '/c', 'mklink', '/J', alias, path.join(root.path, 'local')]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    try {
      await expectLater(
          SettingsService.resolveDataDirectoryForTesting(
              path.join(root.path, 'bin', 'SSRVPN.exe'), alias),
          throwsA(isA<FileSystemException>()));
      expect((await settings())['proxyPort'], 7890);
      await Directory(path.join(root.path, 'local'))
          .rename(path.join(root.path, 'moved-local'));
      await expectLater(
          SettingsService.resolveDataDirectoryForTesting(
              path.join(root.path, 'bin', 'SSRVPN.exe'), alias),
          throwsA(isA<FileSystemException>()));
    } finally {
      final cleanup =
          await Process.run('cmd.exe', ['/d', '/c', 'rmdir', alias]);
      expect(cleanup.exitCode, 0, reason: '${cleanup.stderr}');
    }
  }, skip: !Platform.isWindows);
  test('a broken data-directory link is not an absent migration marker',
      () async {
    final target =
        await Directory(path.join(root.path, 'link-target')).create();
    final link = Link(path.join(root.path, 'broken-store'));
    await link.create(target.path);
    await target.delete();
    await expectLater(WindowsSettingsMigration.isCommitted(link.path),
        throwsA(isA<FileSystemException>()));
  }, skip: Platform.isWindows);
}
