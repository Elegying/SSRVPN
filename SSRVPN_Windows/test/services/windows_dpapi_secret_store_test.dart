import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_dpapi_secret_store.dart';

void main() {
  late Directory tempDirectory;
  late File secretFile;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('ssrvpn-dpapi-');
    secretFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}.api-secret.dpapi',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  WindowsDpapiSecretStore createStore({
    Future<void> Function(File source, File destination)? replaceFile,
    Future<Uint8List> Function(Uint8List encrypted)? unprotect,
  }) {
    return WindowsDpapiSecretStore(
      tempDirectory.path,
      protect: (plainText) async => Uint8List.fromList(plainText),
      unprotect:
          unprotect ?? (encrypted) async => Uint8List.fromList(encrypted),
      replaceFile: replaceFile,
    );
  }

  test('writes through a same-directory temporary file and replaces target',
      () async {
    final store = createStore(
      replaceFile: (source, destination) async {
        if (await destination.exists()) await destination.delete();
        await source.rename(destination.path);
      },
    );

    await store.write('first-secret');
    await store.write('second-secret');

    expect(await store.read(), 'second-secret');
    expect(
      await tempDirectory
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .isEmpty,
      isTrue,
    );
  });

  test('failed atomic replacement preserves the previous durable secret',
      () async {
    await secretFile.writeAsString('old-secret', flush: true);
    final store = createStore(
      replaceFile: (_, __) async => throw FileSystemException('replace failed'),
    );

    await expectLater(
      store.write('new-secret'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await secretFile.readAsString(), 'old-secret');
    expect(
      await tempDirectory
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .isEmpty,
      isTrue,
    );
  });

  test('decryption failure keeps the encrypted recovery evidence', () async {
    await secretFile.writeAsBytes([1, 2, 3], flush: true);
    final store = createStore(
      unprotect: (_) async => throw const FormatException('corrupt payload'),
    );

    await expectLater(
      store.read(),
      throwsA(isA<WindowsApiSecretRecoveryRequired>()),
    );

    expect(await secretFile.readAsBytes(), [1, 2, 3]);
  });

  test('read removes a crash-left encrypted temporary file', () async {
    await secretFile.writeAsString('current-secret', flush: true);
    final stale = File('${secretFile.path}.tmp.crash');
    await stale.writeAsString('old-encrypted-secret', flush: true);
    final store = createStore();

    expect(await store.read(), 'current-secret');
    expect(await stale.exists(), isFalse);
  });

  test('invalid secret length errors do not echo the secret', () async {
    final secret = 'do-not-log-this-${'x' * 4096}';
    final store = createStore();

    Object? failure;
    try {
      await store.write(secret);
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<ArgumentError>());
    expect(failure.toString(), isNot(contains('do-not-log-this')));
  });

  test('refuses a symlink in place of the encrypted secret file', () async {
    final outside = File(
      '${tempDirectory.path}${Platform.pathSeparator}outside-secret',
    );
    await outside.writeAsString('outside');
    await Link(secretFile.path).create(outside.path);
    final store = createStore();

    await expectLater(store.read(), throwsA(isA<FileSystemException>()));
    await expectLater(
      store.write('new-secret'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await outside.readAsString(), 'outside');
  });

  test(
    'real Windows DPAPI and MoveFileEx round-trip survives replacement',
    () async {
      final store = WindowsDpapiSecretStore(tempDirectory.path);

      await store.write('first-real-secret');
      expect(await store.read(), 'first-real-secret');
      await store.write('second-real-secret');

      expect(await store.read(), 'second-real-secret');
      expect(
        await secretFile.readAsBytes(),
        isNot(equals('second-real-secret'.codeUnits)),
      );
    },
    skip: !Platform.isWindows,
  );
}
