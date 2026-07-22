import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
    SharedUpdateService.publicationStepForTesting = null;
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

  test('a mismatched existing destination is rejected without downloading',
      () async {
    final existing = File('${tempDir.path}/SSRVPN_Setup.exe');
    final previousBytes = utf8.encode('previous-verified-installer');
    await existing.writeAsBytes(previousBytes, flush: true);
    final replacementBytes = utf8.encode('latest-verified-installer');
    var requests = 0;

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(replacementBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup.exe',
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes(replacementBytes, HttpStatus.ok);
        }),
      ),
      throwsA(isA<StateError>()),
    );

    expect(requests, 0);
    expect(await existing.readAsBytes(), previousBytes);
    expect(
      tempDir.listSync().map((entry) => entry.path),
      [existing.path],
    );
  });

  test('a matching existing destination is reused without downloading',
      () async {
    final bytes = utf8.encode('already-verified-installer');
    final existing = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    await existing.writeAsBytes(bytes, flush: true);
    var requests = 0;

    final published = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      client: MockClient((_) async {
        requests++;
        return http.Response('unavailable', HttpStatus.badGateway);
      }),
    );

    expect(published.path, existing.path);
    expect(requests, 0);
    expect(await existing.readAsBytes(), bytes);
  });

  test('publication recheck never overwrites a destination created by a race',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final downloadedBytes = utf8.encode('verified-downloaded-installer');
    final racedBytes = utf8.encode('independent-racing-file');
    var injected = false;
    SharedUpdateService.publicationStepForTesting = (step) {
      if (step == VerifiedUpdatePublicationTestStep.beforeDestinationCommit &&
          !injected) {
        injected = true;
        destination.writeAsBytesSync(racedBytes, flush: true);
      }
    };

    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
          changelog: '',
          sha256: sha256.convert(downloadedBytes).toString(),
        ),
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient(
          (_) async => http.Response.bytes(downloadedBytes, HttpStatus.ok),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(injected, isTrue);
    expect(await destination.readAsBytes(), racedBytes);
    expect(
      tempDir.listSync().map((entry) => entry.path),
      [destination.path],
    );
  });

  test('cancellation aborts a publication lock wait without staging leaks',
      () async {
    final bytes = utf8.encode('verified-installer');
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final enteredCommit = Completer<void>();
    final releaseCommit = Completer<void>();
    var blocked = false;
    SharedUpdateService.publicationStepForTesting = (step) async {
      if (step != VerifiedUpdatePublicationTestStep.beforeDestinationCommit ||
          blocked) {
        return;
      }
      blocked = true;
      enteredCommit.complete();
      await releaseCommit.future;
    };
    final update = AppUpdateInfo(
      version: '9.9.9',
      downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
      changelog: '',
      sha256: sha256.convert(bytes).toString(),
    );
    final first = SharedUpdateService.downloadVerifiedUpdate(
      update,
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      client: MockClient(
        (_) async => http.Response.bytes(bytes, HttpStatus.ok),
      ),
    );
    await enteredCommit.future;

    final cancellation = VerifiedUpdateCancellation();
    final second = SharedUpdateService.downloadVerifiedUpdate(
      update,
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      cancellation: cancellation,
      client: MockClient(
        (_) async => http.Response.bytes(bytes, HttpStatus.ok),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 25));
    cancellation.cancel();
    await expectLater(second, throwsA(isA<VerifiedUpdateCancelled>()));

    releaseCommit.complete();
    await first;
    expect(await destination.readAsBytes(), bytes);
    expect(
      tempDir.listSync().where((entry) => entry.path.contains('.part.')),
      isEmpty,
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

    expect(hosts, isEmpty);
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

    var requests = 0;
    final published = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(expectedBytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      client: MockClient((_) async {
        requests++;
        return http.Response('unavailable', HttpStatus.badGateway);
      }),
    );

    expect(published.path, destination.path);
    expect(requests, 0);
    expect(await destination.readAsBytes(), expectedBytes);
    expect(await backup.exists(), isFalse);
    expect(tempDir.listSync().map((entry) => entry.path), [destination.path]);
  });

  test('two concurrent recoveries reuse one verified canonical artifact',
      () async {
    final destination = File('${tempDir.path}/SSRVPN_Setup_v9.9.9.exe');
    final backup = File(
      '${destination.path}.previous.123_456_789',
    );
    final expectedBytes = utf8.encode('expected-verified-installer');
    await backup.writeAsBytes(expectedBytes, flush: true);
    var requests = 0;
    final update = AppUpdateInfo(
      version: '9.9.9',
      downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
      changelog: '',
      sha256: sha256.convert(expectedBytes).toString(),
    );

    final results = await Future.wait([
      SharedUpdateService.downloadVerifiedUpdate(
        update,
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient((_) async {
          requests++;
          return http.Response('unavailable', HttpStatus.badGateway);
        }),
      ),
      SharedUpdateService.downloadVerifiedUpdate(
        update,
        outputDirectory: tempDir,
        fileName: 'SSRVPN_Setup_v9.9.9.exe',
        client: MockClient((_) async {
          requests++;
          return http.Response('unavailable', HttpStatus.badGateway);
        }),
      ),
    ]);

    expect(results.map((file) => file.path), everyElement(destination.path));
    expect(requests, 0);
    expect(await destination.readAsBytes(), expectedBytes);
    expect(await backup.exists(), isFalse);
  });

  test('concurrent isolates cannot replace each other verified publication',
      () async {
    final receivePort = ReceivePort();
    addTearDown(receivePort.close);
    final ready = <int, Completer<void>>{
      1: Completer<void>(),
      2: Completer<void>(),
    };
    final results = <int, Completer<String>>{
      1: Completer<String>(),
      2: Completer<String>(),
    };
    receivePort.listen((message) {
      final fields = message as List<Object?>;
      final id = fields[0]! as int;
      final state = fields[1]! as String;
      if (state == 'ready') {
        ready[id]!.complete();
      } else {
        results[id]!.complete(state);
      }
    });
    final destinationName = 'SSRVPN_Setup_v9.9.9.exe';
    final firstBytes = utf8.encode('isolate-one-verified-payload');
    final secondBytes = utf8.encode('isolate-two-verified-payload');
    final startGate = File('${tempDir.path}/start-publication');
    final isolates = <Isolate>[
      await Isolate.spawn(_runIsolateUpdate, [
        receivePort.sendPort,
        1,
        tempDir.path,
        destinationName,
        firstBytes,
      ]),
      await Isolate.spawn(_runIsolateUpdate, [
        receivePort.sendPort,
        2,
        tempDir.path,
        destinationName,
        secondBytes,
      ]),
    ];
    addTearDown(() {
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    });

    await Future.wait(ready.values.map((item) => item.future));
    await startGate.writeAsString('go', flush: true);
    await Future.wait([
      _waitForFile(File('${tempDir.path}/network-1-ready')),
      _waitForFile(File('${tempDir.path}/network-2-ready')),
    ]);
    await File('${tempDir.path}/release-network').writeAsString(
      'go',
      flush: true,
    );
    final states = await Future.wait(
      results.values.map(
        (item) => item.future.timeout(const Duration(seconds: 20)),
      ),
    );

    expect(states.where((state) => state == 'published'), hasLength(1));
    expect(states.where((state) => state == 'rejected'), hasLength(1));
    final publishedBytes = await File(
      '${tempDir.path}/$destinationName',
    ).readAsBytes();
    expect(
      publishedBytes,
      anyOf(orderedEquals(firstBytes), orderedEquals(secondBytes)),
    );
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

    var requests = 0;
    final published = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(expectedBytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      client: MockClient((_) async {
        requests++;
        return http.Response('unavailable', HttpStatus.badGateway);
      }),
    );

    expect(published.path, destination.path);
    expect(requests, 0);
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

    var requests = 0;
    final published = await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(expectedBytes).toString(),
      ),
      outputDirectory: tempDir,
      fileName: 'SSRVPN_Setup_v9.9.9.exe',
      client: MockClient((_) async {
        requests++;
        return http.Response('unavailable', HttpStatus.badGateway);
      }),
    );

    expect(published.path, destination.path);
    expect(requests, 0);
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
    final destination = File('${tempDir.path}/SSRVPN.dmg');

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

    expect(await destination.exists(), isFalse);
    expect(tempDir.listSync(), isEmpty);
  });

  test('verified desktop download enforces one absolute attempt deadline',
      () async {
    final chunks = List<List<int>>.generate(6, (index) => [index]);
    final bytes = chunks.expand((chunk) => chunk).toList();
    final destination = File('${tempDir.path}/SSRVPN.dmg');
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
    expect(await destination.exists(), isFalse);
    expect(tempDir.listSync(), isEmpty);
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

Future<void> _runIsolateUpdate(List<Object?> arguments) async {
  final sendPort = arguments[0]! as SendPort;
  final id = arguments[1]! as int;
  final directoryPath = arguments[2]! as String;
  final destinationName = arguments[3]! as String;
  final bytes = (arguments[4]! as List<Object?>).cast<int>();
  final startGate = File('$directoryPath/start-publication');
  sendPort.send(<Object?>[id, 'ready']);
  while (!await startGate.exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  try {
    await SharedUpdateService.downloadVerifiedUpdate(
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      outputDirectory: Directory(directoryPath),
      fileName: destinationName,
      client: MockClient((_) async {
        await File('$directoryPath/network-$id-ready').writeAsString(
          'ready',
          flush: true,
        );
        await _waitForFile(File('$directoryPath/release-network'));
        return http.Response.bytes(bytes, HttpStatus.ok);
      }),
    );
    sendPort.send(<Object?>[id, 'published']);
  } on StateError {
    sendPort.send(<Object?>[id, 'rejected']);
  } catch (_) {
    sendPort.send(<Object?>[id, 'unexpected']);
  }
}

Future<void> _waitForFile(File file) async {
  final deadline = Stopwatch()..start();
  while (!await file.exists()) {
    // This handshake surrounds production code whose publication-lock timeout
    // is 15 seconds. Keep the test deadline above that bound so a loaded test
    // host does not fail before the production operation can resolve itself.
    if (deadline.elapsed > const Duration(seconds: 20)) {
      throw TimeoutException('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
