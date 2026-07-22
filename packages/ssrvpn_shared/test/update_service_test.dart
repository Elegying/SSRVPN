import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/services/update_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ssrvpn-shared-update-');
  });

  tearDown(() async {
    SharedUpdateService.recoveryDirectoryEntryLimitForTesting = null;
    SharedUpdateService.recoveryStepForTesting = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('verified desktop download enforces SHA256 before returning a file',
      () async {
    final bytes = utf8.encode('verified-installer');
    final file = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup.exe',
      client: MockClient(
        (_) async => http.Response.bytes(bytes, HttpStatus.ok),
      ),
    );

    expect(await file.readAsBytes(), bytes);
  });

  test('verified desktop download removes a checksum mismatch', () async {
    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.dmg',
          changelog: '',
          sha256: '0' * 64,
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN.dmg',
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('tampered'),
            HttpStatus.ok,
          ),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(tempDir.listSync(), isEmpty);
  });

  test('checksum mismatch preserves an existing verified installer', () async {
    final existing = File('${tempDir.path}/SSRVPN_Setup.exe');
    final previousBytes = utf8.encode('previous-verified-installer');
    await existing.writeAsBytes(previousBytes, flush: true);

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: '0' * 64,
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup.exe',
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('tampered-new-installer'),
            HttpStatus.ok,
          ),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await existing.readAsBytes(), previousBytes);
    expect(
      tempDir.listSync().map((entry) => entry.path),
      [existing.path],
    );
  });

  test('verified replacement removes its private backup after publication',
      () async {
    final existing = File('${tempDir.path}/SSRVPN_Setup.exe');
    await existing.writeAsString('previous-verified-installer', flush: true);
    final replacementBytes = utf8.encode('latest-verified-installer');

    final published = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(replacementBytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup.exe',
      client: MockClient(
        (_) async => http.Response.bytes(replacementBytes, HttpStatus.ok),
      ),
    );

    expect(published.path, existing.path);
    expect(await existing.readAsBytes(), replacementBytes);
    expect(
      tempDir.listSync().map((entry) => entry.path),
      [existing.path],
    );
  });

  test('verified desktop download falls back after an OSS failure', () async {
    final bytes = utf8.encode('github-installer');
    final hosts = <String>[];
    final file = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://oss.example/SSRVPN_Setup.exe',
        fallbackDownloadUrl:
            'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup.exe',
      client: MockClient((request) async {
        hosts.add(request.url.host);
        return request.url.host == 'oss.example'
            ? http.Response('unavailable', HttpStatus.badGateway)
            : http.Response.bytes(bytes, HttpStatus.ok);
      }),
    );

    expect(await file.readAsBytes(), bytes);
    expect(hosts, ['oss.example', 'github.com']);
  });

  test('selected fallback download is attempted before the primary', () async {
    final bytes = utf8.encode('github-installer');
    const fallback =
        'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN_Setup.exe';
    final hosts = <String>[];
    final update = SharedUpdateService.preferDownloadUrl(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://oss.example/SSRVPN_Setup.exe',
        fallbackDownloadUrl: fallback,
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      fallback,
    );

    await SharedUpdateService.downloadVerifiedUpdate(
      update,
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup.exe',
      client: MockClient((request) async {
        hosts.add(request.url.host);
        return http.Response.bytes(bytes, HttpStatus.ok);
      }),
    );

    expect(hosts, ['github.com']);
    expect(update.fallbackDownloadUrl, 'https://oss.example/SSRVPN_Setup.exe');
  });

  test('a publication failure does not retry from another download source',
      () async {
    final bytes = utf8.encode('verified-installer');
    final destinationDirectory = Directory('${tempDir.path}/SSRVPN_Setup.exe');
    await destinationDirectory.create();
    final hosts = <String>[];

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://oss.example/SSRVPN_Setup.exe',
          fallbackDownloadUrl:
              'https://github.com/Elegying/SSRVPN/releases/download/v9.9.9/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup.exe',
        client: MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response.bytes(bytes, HttpStatus.ok);
        }),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(hosts, ['oss.example']);
    expect(destinationDirectory.existsSync(), isTrue);
    expect(
      tempDir.listSync().whereType<File>(),
      isEmpty,
    );
  });

  test('HTTP failure preserves an existing installer', () async {
    final existing = File('${tempDir.path}/SSRVPN_Setup.exe');
    final previousBytes = utf8.encode('previous-verified-installer');
    await existing.writeAsBytes(previousBytes, flush: true);

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await existing.readAsBytes(), previousBytes);
    expect(tempDir.listSync().map((entry) => entry.path), [existing.path]);
  });

  test('an interrupted replacement with a mismatched digest is not restored',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    final expectedBytes = utf8.encode('expected-verified-installer');
    await backup.writeAsString('unverified-installer', flush: true);

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.exists(), isFalse);
    expect(await backup.exists(), isFalse);
    expect(tempDir.listSync(), isEmpty);
  });

  test('an interrupted replacement with the expected digest is restored',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    final expectedBytes = utf8.encode('expected-verified-installer');
    await backup.writeAsBytes(expectedBytes, flush: true);

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.readAsBytes(), expectedBytes);
    expect(await backup.exists(), isFalse);
    expect(tempDir.listSync().map((entry) => entry.path), [destination.path]);
  });

  test('recovery finds a verified backup among multiple previous files',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = utf8.encode('expected-verified-installer');
    final matchingBackup = File(
      '${destination.path}.previous.123_456_789',
    );
    final newerMismatch = File(
      '${destination.path}.previous.223_556_889',
    );
    await matchingBackup.writeAsBytes(expectedBytes, flush: true);
    await newerMismatch.writeAsString('mismatched-installer', flush: true);
    await matchingBackup.setLastModified(DateTime.utc(2026));
    await newerMismatch.setLastModified(
      DateTime.utc(2026).add(const Duration(seconds: 1)),
    );

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.readAsBytes(), expectedBytes);
    expect(await matchingBackup.exists(), isFalse);
    expect(await newerMismatch.exists(), isFalse);
  });

  test('interrupted publication recovery only considers 16 newest backups',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = <int>[9, 9, 9, 9];
    final oldestMatchingBackup = File(
      '${destination.path}.previous.100_100_100',
    );
    await oldestMatchingBackup.writeAsBytes(expectedBytes, flush: true);
    await oldestMatchingBackup.setLastModified(DateTime.utc(2026));

    for (var index = 0; index < 16; index++) {
      final backup = File(
        '${destination.path}.previous.${200 + index}_${300 + index}_${400 + index}',
      );
      await backup.writeAsBytes(<int>[index, 1, 2, 3], flush: true);
      await backup.setLastModified(
        DateTime.utc(2026).add(Duration(seconds: index + 1)),
      );
    }

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.exists(), isFalse);
  });

  test('interrupted publication recovery hashes at most twice maxBytes',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = <int>[9, 9, 9, 9];
    final backups = <File>[
      File('${destination.path}.previous.100_100_100'),
      File('${destination.path}.previous.200_200_200'),
      File('${destination.path}.previous.300_300_300'),
    ];
    await backups[0].writeAsBytes(expectedBytes, flush: true);
    await backups[1].writeAsBytes(<int>[1, 1, 1, 1], flush: true);
    await backups[2].writeAsBytes(<int>[2, 2, 2, 2], flush: true);
    for (var index = 0; index < backups.length; index++) {
      await backups[index].setLastModified(
        DateTime.utc(2026).add(Duration(seconds: index)),
      );
    }

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        maxBytes: expectedBytes.length,
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.exists(), isFalse);
  });

  test('cancellation interrupts an in-progress recovery directory scan',
      () async {
    final cancellation = VerifiedUpdateCancellation();
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = utf8.encode('expected-verified-installer');
    final backups = <File>[];
    for (var index = 0; index < 4; index++) {
      final backup = File(
        '${destination.path}.previous.${100 + index}_${200 + index}_${300 + index}',
      );
      await backup.writeAsBytes(
        index == 0 ? expectedBytes : utf8.encode('mismatch-$index'),
        flush: true,
      );
      backups.add(backup);
    }
    var scannedEntries = 0;
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step != VerifiedUpdateRecoveryTestStep.scanEntry) return;
      scannedEntries++;
      if (scannedEntries == 2) cancellation.cancel();
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        cancellation: cancellation,
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<VerifiedUpdateCancelled>()),
    );

    expect(await destination.exists(), isFalse);
    expect(await backups[0].exists(), isTrue);
  });

  test('interrupted publication recovery bounds directory entries scanned',
      () async {
    for (var index = 0; index < 4; index++) {
      await File('${tempDir.path}/unrelated-$index.txt')
          .writeAsString('$index');
    }
    SharedUpdateService.recoveryDirectoryEntryLimitForTesting = 2;
    var scannedEntries = 0;
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step == VerifiedUpdateRecoveryTestStep.scanEntry) scannedEntries++;
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(scannedEntries, 2);
  });

  test('cancellation interrupts chunked hashing of a recovery candidate',
      () async {
    final cancellation = VerifiedUpdateCancellation();
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = List<int>.filled(128 * 1024, 7);
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    await backup.writeAsBytes(expectedBytes, flush: true);
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step == VerifiedUpdateRecoveryTestStep.hashedChunk) {
        cancellation.cancel();
      }
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        cancellation: cancellation,
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<VerifiedUpdateCancelled>()),
    );

    expect(await destination.exists(), isFalse);
    expect(await backup.exists(), isTrue);
    expect(tempDir.listSync().map((entry) => entry.path), [backup.path]);
  });

  test('cancellation after recovery rename keeps the verified destination',
      () async {
    final cancellation = VerifiedUpdateCancellation();
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = utf8.encode('expected-verified-installer');
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    await backup.writeAsBytes(expectedBytes, flush: true);
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step == VerifiedUpdateRecoveryTestStep.committed) {
        cancellation.cancel();
      }
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        cancellation: cancellation,
        client: MockClient((_) async => throw StateError('unexpected request')),
      ),
      throwsA(isA<VerifiedUpdateCancelled>()),
    );

    expect(await destination.readAsBytes(), expectedBytes);
    expect(await backup.readAsBytes(), expectedBytes);
  });

  test('recovery commits the same private file object that was verified',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = <int>[1, 2, 3, 4];
    final replacementBytes = <int>[4, 3, 2, 1];
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    await backup.writeAsBytes(expectedBytes, flush: true);
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step == VerifiedUpdateRecoveryTestStep.verifiedCopy) {
        backup.writeAsBytesSync(replacementBytes, flush: true);
      }
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.readAsBytes(), expectedBytes);
    expect(await backup.exists(), isFalse);
  });

  test('recovery write failure removes staging and preserves the source backup',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = utf8.encode('expected-verified-installer');
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    await backup.writeAsBytes(expectedBytes, flush: true);
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step == VerifiedUpdateRecoveryTestStep.beforeStagingWrite) {
        throw FileSystemException('No space left on device');
      }
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(expectedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient((_) async => throw StateError('unexpected request')),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await destination.exists(), isFalse);
    expect(await backup.readAsBytes(), expectedBytes);
    expect(tempDir.listSync().map((entry) => entry.path), [backup.path]);
  });

  test('unreadable recovery source does not block the verified download',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final expectedBytes = utf8.encode('expected-verified-installer');
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    await backup.writeAsBytes(expectedBytes, flush: true);
    SharedUpdateService.recoveryStepForTesting = (step) {
      if (step == VerifiedUpdateRecoveryTestStep.beforeSourceRead) {
        throw FileSystemException('source read failed');
      }
    };

    final published = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(expectedBytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      client: MockClient(
        (_) async => http.Response.bytes(expectedBytes, HttpStatus.ok),
      ),
    );

    expect(await published.readAsBytes(), expectedBytes);
    expect(await backup.exists(), isFalse);
    expect(tempDir.listSync().map((entry) => entry.path), [destination.path]);
  });

  test('recovery never overwrites an existing destination', () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final destinationBytes = utf8.encode('existing-installer');
    await destination.writeAsBytes(destinationBytes, flush: true);
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    final backupBytes = utf8.encode('expected-verified-installer');
    await backup.writeAsBytes(backupBytes, flush: true);

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(backupBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response('unavailable', HttpStatus.badGateway),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await destination.readAsBytes(), destinationBytes);
    expect(await backup.exists(), isFalse);
    expect(tempDir.listSync().map((entry) => entry.path), [destination.path]);
  });

  test('verified desktop download cancellation interrupts a stalled request',
      () async {
    final response = Completer<http.StreamedResponse>();
    final cancellation = VerifiedUpdateCancellation();
    final task = SharedUpdateService.downloadVerifiedUpdate(
      const AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN.dmg',
        changelog: '',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN.dmg',
      client: _StreamClient((_) => response.future),
      cancellation: cancellation,
    );

    cancellation.cancel();

    await expectLater(task, throwsA(isA<VerifiedUpdateCancelled>()));
    expect(tempDir.listSync(), isEmpty);
  });

  test('cancellation keeps an injected client open and cancels a late response',
      () async {
    final response = Completer<http.StreamedResponse>();
    final sendStarted = Completer<void>();
    final streamCancelled = Completer<void>();
    final responseStream = StreamController<List<int>>(
      onCancel: streamCancelled.complete,
    );
    addTearDown(responseStream.close);
    final client = _TrackingStreamClient((_) {
      if (!sendStarted.isCompleted) sendStarted.complete();
      return response.future;
    });
    final cancellation = VerifiedUpdateCancellation();
    final task = SharedUpdateService.downloadVerifiedUpdate(
      const AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN.dmg',
        changelog: '',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN.dmg',
      client: client,
      cancellation: cancellation,
    );
    await sendStarted.future;

    cancellation.cancel();
    await expectLater(task, throwsA(isA<VerifiedUpdateCancelled>()));
    expect(client.closed, isFalse);

    response.complete(http.StreamedResponse(responseStream.stream, 200));
    await streamCancelled.future.timeout(const Duration(seconds: 1));
  });

  test('cancellation after the final progress event prevents publication',
      () async {
    final bytes = utf8.encode('verified-installer');
    final cancellation = VerifiedUpdateCancellation();
    final existing = File('${tempDir.path}/SSRVPN.dmg');
    final previousBytes = utf8.encode('previous-verified-installer');
    await existing.writeAsBytes(previousBytes, flush: true);

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.dmg',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN.dmg',
        client: MockClient(
          (_) async => http.Response.bytes(bytes, HttpStatus.ok),
        ),
        cancellation: cancellation,
        onProgress: (_, __) => cancellation.cancel(),
      ),
      throwsA(isA<VerifiedUpdateCancelled>()),
    );

    expect(await existing.readAsBytes(), previousBytes);
    expect(tempDir.listSync().map((entry) => entry.path), [existing.path]);
  });

  test('verified desktop download enforces one absolute attempt deadline',
      () async {
    final chunks = List<List<int>>.generate(6, (index) => [index]);
    final bytes = chunks.expand((chunk) => chunk).toList();
    final existing = File('${tempDir.path}/SSRVPN.dmg');
    final previousBytes = utf8.encode('previous-verified-installer');
    await existing.writeAsBytes(previousBytes, flush: true);
    final client = _StreamClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.periodic(
          const Duration(milliseconds: 25),
          (index) => chunks[index],
        ).take(chunks.length),
        HttpStatus.ok,
      ),
    );

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.dmg',
          changelog: '',
          sha256: sha256.convert(bytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN.dmg',
        client: client,
        timeout: const Duration(milliseconds: 70),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await existing.readAsBytes(), previousBytes);
    expect(tempDir.listSync().map((entry) => entry.path), [existing.path]);
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

class _TrackingStreamClient extends _StreamClient {
  _TrackingStreamClient(super.handler);

  bool closed = false;

  @override
  void close() {
    closed = true;
  }
}
