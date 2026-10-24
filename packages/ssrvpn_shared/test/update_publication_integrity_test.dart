import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/services/update_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssrvpn-publication-');
  });
  tearDown(() async => directory.delete(recursive: true));

  for (final matches in [true, false]) {
    test('publisher collision only reuses verified bytes, matches=$matches',
        () async {
      final expected = utf8.encode('verified-installer');
      final competing = matches ? expected : utf8.encode('untrusted-content');
      final destination = File('${directory.path}/installer.exe');
      final requests = <String>[];
      var publisherCalls = 0;
      final client = MockClient((request) async {
        requests.add(request.url.host);
        return http.Response.bytes(expected, HttpStatus.ok);
      });
      addTearDown(client.close);
      final download = SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://primary.example/installer.exe',
          fallbackDownloadUrl: 'https://backup.example/installer.exe',
          changelog: '',
          sha256: sha256.convert(expected).toString(),
        ),
        outputDirectory: directory,
        fileName: 'installer.exe',
        client: client,
        filePublisher: (source, target) async {
          publisherCalls++;
          expect(await source.readAsBytes(), expected);
          await target.writeAsBytes(competing, flush: true);
          throw const FileSystemException('another publisher won');
        },
      );
      if (matches) {
        expect((await download).path, destination.path);
      } else {
        await expectLater(download, throwsA(isA<StateError>()));
      }
      expect(requests, ['primary.example']);
      expect(publisherCalls, 1);
      expect(await destination.readAsBytes(), competing);
      expect(directory.listSync().map((entry) => entry.uri), [destination.uri]);
    });
  }

  test('publisher success cannot bypass verification of committed bytes',
      () async {
    final expected = utf8.encode('verified-installer');
    final corrupted = utf8.encode('changed-after-validation');
    final destination = File('${directory.path}/installer.exe');
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response.bytes(expected, HttpStatus.ok);
    });
    addTearDown(client.close);
    await expectLater(
      SharedUpdateService.downloadVerifiedUpdate(
        AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://primary.example/installer.exe',
          fallbackDownloadUrl: 'https://backup.example/installer.exe',
          changelog: '',
          sha256: sha256.convert(expected).toString(),
        ),
        outputDirectory: directory,
        fileName: 'installer.exe',
        client: client,
        filePublisher: (source, target) async {
          expect(await source.readAsBytes(), expected);
          await source.rename(target.path);
          await target.writeAsBytes(corrupted, flush: true);
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(requests, 1);
    // A failed verification must not silently delete a committed destination.
    expect(await destination.readAsBytes(), corrupted);
    expect(directory.listSync().map((entry) => entry.uri), [destination.uri]);
  });
}
