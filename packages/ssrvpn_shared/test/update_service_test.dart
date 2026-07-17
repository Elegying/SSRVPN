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

  test('verified desktop download enforces one absolute attempt deadline',
      () async {
    final chunks = List<List<int>>.generate(6, (index) => [index]);
    final bytes = chunks.expand((chunk) => chunk).toList();
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
